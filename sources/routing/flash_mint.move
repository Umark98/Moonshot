/// Flash Mint module — enables atomic PT/YT operations within a single PTB.
/// Uses Sui Move's "hot potato" pattern: a struct with no abilities that MUST be consumed
/// in the same transaction. This provides flash-loan-like functionality with
/// language-level safety guarantees (no callbacks, no reentrancy risk).
///
/// Key use case: Flash-minting PT+YT to facilitate YT swaps.
/// Instead of needing to own SY upfront to mint PT+YT:
///   1. Flash mint PT + YT (receive both + receipt)
///   2. Sell the PT on the AMM for SY
///   3. Repay the receipt with SY
///   4. Keep the YT (or vice versa)
///
/// All steps execute atomically in one PTB. If any step fails, everything reverts.
module crux::flash_mint {

    use sui::clock::Clock;
    use sui::event;

    use sui::coin::Coin;
    use crux::yield_tokenizer::{Self, YieldMarketConfig, PT, YT};
    use crux::standardized_yield::{Self, SYVault, SYToken};

    // ===== Error Codes =====

    const EInsufficientRepayment: u64 = 400;
    const EZeroAmount: u64 = 401;
    const EMarketExpired: u64 = 402;

    // ===== Hot Potato Struct =====

    /// Flash mint receipt — a "hot potato" that MUST be consumed in the same PTB.
    /// Has NO abilities (no key, store, copy, or drop), so it cannot be:
    ///   - Stored in global storage
    ///   - Transferred to another address
    ///   - Dropped/ignored
    ///   - Copied
    /// The only way to get rid of it is to pass it to `repay_flash_mint`.
    public struct FlashMintReceipt<phantom T> {
        /// Amount of SY that must be repaid
        sy_amount_owed: u64,
        /// The market this receipt belongs to
        market_config_id: ID,
        /// Small fee for flash minting (in SY units)
        fee: u64,
    }

    // ===== Events =====

    public struct FlashMintExecuted has copy, drop {
        market_config_id: ID,
        borrower: address,
        sy_amount: u64,
        pt_minted: u64,
        yt_minted: u64,
        fee: u64,
    }

    public struct FlashMintRepaid has copy, drop {
        market_config_id: ID,
        borrower: address,
        sy_repaid: u64,
    }

    // ===== Constants =====

    /// Flash mint fee: 0.01% (1 basis point) in WAD
    const FLASH_MINT_FEE_WAD: u128 = 100_000_000_000_000; // 0.0001 * 1e18
    const WAD: u128 = 1_000_000_000_000_000_000;

    // ===== Flash Mint Operations =====

    /// Flash mint PT + YT without upfront SY.
    /// Returns PT, YT, and a receipt that must be repaid with SY in the same PTB.
    ///
    /// Usage pattern in a PTB:
    ///   let (pt, yt, receipt) = flash_mint(config, amount, clock, ctx);
    ///   // ... use pt and/or yt (e.g., sell PT on AMM) ...
    ///   repay_flash_mint(config, vault, receipt, sy_payment);
    public fun flash_mint<T>(
        config: &mut YieldMarketConfig<T>,
        amount: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): (PT<T>, YT<T>, FlashMintReceipt<T>) {
        assert!(amount > 0, EZeroAmount);
        assert!(!yield_tokenizer::is_expired(config), EMarketExpired);
        assert!(clock.timestamp_ms() < yield_tokenizer::maturity_ms(config), EMarketExpired);

        let market_config_id = yield_tokenizer::market_config_id(config);

        // Calculate fee
        let fee = ((amount as u128) * FLASH_MINT_FEE_WAD / WAD as u64);
        let fee = if (fee == 0) { 1 } else { fee }; // Minimum 1 unit fee

        // Create PT and YT via package-internal functions (friend access pattern).
        // These update supply tracking in YieldMarketConfig.
        let pt = yield_tokenizer::create_pt_internal(config, amount, ctx);
        let yt = yield_tokenizer::create_yt_internal(config, amount, ctx);

        let receipt = FlashMintReceipt<T> {
            sy_amount_owed: amount,
            market_config_id,
            fee,
        };

        event::emit(FlashMintExecuted {
            market_config_id,
            borrower: ctx.sender(),
            sy_amount: amount,
            pt_minted: amount,
            yt_minted: amount,
            fee,
        });

        (pt, yt, receipt)
    }

    /// Repay a flash mint receipt with SY tokens.
    /// The SY payment must cover the owed amount + fee.
    /// This consumes the hot potato receipt, completing the flash mint.
    /// SECURITY: SY is now frozen as reserve backing rather than lost.
    /// The supply tracking in YieldMarketConfig accounts for the minted PT+YT.
    /// Repay a flash mint receipt with underlying tokens.
    /// MAINNET: The underlying is deposited into the YieldMarketConfig's real reserve,
    /// backing the PT+YT that were created in flash_mint.
    public fun repay_flash_mint<T>(
        config: &mut YieldMarketConfig<T>,
        vault: &SYVault<T>,
        receipt: FlashMintReceipt<T>,
        mut payment: Coin<T>,
        ctx: &mut TxContext,
    ) {
        let FlashMintReceipt { sy_amount_owed, market_config_id, fee } = receipt;

        // Convert SY owed to underlying amount
        let total_sy_owed = sy_amount_owed + fee;
        let underlying_owed = crux::fixed_point::from_wad(
            crux::fixed_point::wad_mul(
                crux::fixed_point::to_wad(total_sy_owed),
                standardized_yield::exchange_rate(vault),
            )
        );

        let payment_amount = payment.value();
        assert!(payment_amount >= underlying_owed, EInsufficientRepayment);

        // SECURITY: Refund excess payment
        if (payment_amount > underlying_owed) {
            let refund_coin = payment.split(underlying_owed, ctx);
            // Transfer the remaining (excess) back to user
            sui::transfer::public_transfer(payment, ctx.sender());
            // Use the exact amount for deposit
            yield_tokenizer::deposit_to_reserve(config, refund_coin);
        } else {
            // Exact payment — deposit all into config reserve
            yield_tokenizer::deposit_to_reserve(config, payment);
        };

        event::emit(FlashMintRepaid {
            market_config_id,
            borrower: ctx.sender(),
            sy_repaid: total_sy_owed,
        });
    }

    /// Get the amount owed on a flash mint receipt
    public fun amount_owed<T>(receipt: &FlashMintReceipt<T>): u64 {
        receipt.sy_amount_owed + receipt.fee
    }

    /// Get the fee on a flash mint receipt
    public fun receipt_fee<T>(receipt: &FlashMintReceipt<T>): u64 {
        receipt.fee
    }

    #[test_only]
    /// Destroy a receipt in tests (e.g., expected_failure tests that abort before repayment)
    public fun destroy_receipt_for_testing<T>(receipt: FlashMintReceipt<T>) {
        let FlashMintReceipt { sy_amount_owed: _, market_config_id: _, fee: _ } = receipt;
    }

}
