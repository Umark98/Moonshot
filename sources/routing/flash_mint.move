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
    public fun repay_flash_mint<T>(
        _vault: &mut SYVault<T>,
        receipt: FlashMintReceipt<T>,
        payment: SYToken<T>,
        ctx: &mut TxContext,
    ) {
        let FlashMintReceipt { sy_amount_owed, market_config_id, fee } = receipt;

        let payment_amount = standardized_yield::sy_amount(&payment);
        let total_owed = sy_amount_owed + fee;

        assert!(payment_amount >= total_owed, EInsufficientRepayment);

        event::emit(FlashMintRepaid {
            market_config_id,
            borrower: ctx.sender(),
            sy_repaid: payment_amount,
        });

        // The SY payment backs the minted PT+YT.
        // In full implementation, this would be deposited into the market's reserve.
        // For now, freeze the SY as backing.
        sui::transfer::public_freeze_object(payment);
    }

    /// Get the amount owed on a flash mint receipt
    public fun amount_owed<T>(receipt: &FlashMintReceipt<T>): u64 {
        receipt.sy_amount_owed + receipt.fee
    }

    /// Get the fee on a flash mint receipt
    public fun receipt_fee<T>(receipt: &FlashMintReceipt<T>): u64 {
        receipt.fee
    }

}
