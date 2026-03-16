/// Router — PTB-optimized entry points for Crux Protocol.
/// Provides high-level convenience functions that compose multiple internal operations
/// into single callable functions, optimized for Sui's Programmable Transaction Blocks.
///
/// Users and frontend SDKs can either:
///   1. Use these router functions for common operations (simpler)
///   2. Compose their own PTBs from lower-level functions (more flexible)
///
/// Key strategies enabled:
///   - Fixed-rate deposit (deposit underlying → wrap SY → buy PT)
///   - Leveraged yield (deposit → wrap → mint PT+YT → sell PT → keep YT)
///   - Yield claim & compound
///   - Position rollover at maturity
module crux::router {

    use sui::coin::Coin;
    use sui::clock::Clock;
    use sui::event;

    use crux::standardized_yield::{Self, SYVault};
    use crux::yield_tokenizer::{Self, YieldMarketConfig, YT};
    use crux::rate_market::{Self, YieldPool};

    // ===== Error Codes =====

    const ESlippageExceeded: u64 = 600;
    const EZeroAmount: u64 = 601;

    // ===== Events =====

    public struct FixedRateDeposit has copy, drop {
        user: address,
        underlying_amount: u64,
        pt_received: u64,
        implied_fixed_rate: u128,
        maturity_ms: u64,
    }

    public struct LeveragedYieldEntry has copy, drop {
        user: address,
        underlying_amount: u64,
        yt_received: u64,
        leverage_factor: u128,
        maturity_ms: u64,
    }

    // ===== Fixed-Rate Strategies =====

    /// One-click fixed-rate deposit.
    /// Deposits underlying tokens and converts them to PT for guaranteed fixed yield.
    ///
    /// Flow: Underlying → SY (wrap) → Swap SY for PT on AMM → Transfer PT to user
    ///
    /// The user receives PT, which is redeemable at maturity for a known amount,
    /// locking in the current implied fixed rate.
    ///
    /// Example: Deposit 1000 haSUI, get PT-haSUI at 7% fixed rate for 6 months.
    #[allow(lint(self_transfer))]
    public fun fixed_rate_deposit<T>(
        vault: &mut SYVault<T>,
        pool: &mut YieldPool<T>,
        config: &mut YieldMarketConfig<T>,
        underlying: Coin<T>,
        min_pt_out: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        let underlying_amount = underlying.value();
        assert!(underlying_amount > 0, EZeroAmount);

        // Step 1: Deposit underlying into SY vault
        let sy_token = standardized_yield::deposit(vault, underlying, ctx);

        // Step 2: Swap SY for PT on the AMM (now returns actual PT object)
        let pt = rate_market::swap_sy_for_pt(pool, config, sy_token, min_pt_out, clock, ctx);

        let pt_out = yield_tokenizer::pt_amount(&pt);
        let implied_rate = rate_market::current_implied_rate(pool);

        event::emit(FixedRateDeposit {
            user: ctx.sender(),
            underlying_amount,
            pt_received: pt_out,
            implied_fixed_rate: implied_rate,
            maturity_ms: rate_market::pool_maturity(pool),
        });

        // Transfer PT to the user
        sui::transfer::public_transfer(pt, ctx.sender());
    }

    /// Preview fixed-rate deposit: shows how much PT and what rate the user would get.
    public fun preview_fixed_rate_deposit<T>(
        vault: &SYVault<T>,
        pool: &YieldPool<T>,
        underlying_amount: u64,
        clock: &Clock,
    ): (u64, u128) {
        // Preview SY amount from deposit
        let sy_amount = standardized_yield::preview_deposit(vault, underlying_amount);

        // Preview PT output from swap
        let pt_out = rate_market::preview_swap_sy_for_pt(pool, sy_amount, clock);

        // Current implied rate
        let implied_rate = rate_market::current_implied_rate(pool);

        (pt_out, implied_rate)
    }

    // ===== Leveraged Yield Strategies =====

    /// Deposit underlying and mint PT+YT, then sell PT to keep leveraged yield exposure.
    ///
    /// Flow: Underlying → SY → Mint PT+YT → Sell PT for SY → Return excess SY + keep YT
    ///
    /// The user receives YT (leveraged yield exposure) and any excess SY from selling PT.
    /// The YT accrues all variable yield from the underlying until maturity.
    ///
    /// NOTE: This is a simplified version. The full implementation would use flash_mint
    /// for maximum capital efficiency. This version requires the user to own the full
    /// underlying amount upfront.
    #[allow(lint(self_transfer))]
    public fun deposit_and_get_yt<T>(
        vault: &mut SYVault<T>,
        config: &mut YieldMarketConfig<T>,
        pool: &mut YieldPool<T>,
        underlying: Coin<T>,
        min_yt_amount: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        let underlying_amount = underlying.value();
        assert!(underlying_amount > 0, EZeroAmount);

        // Step 1: Deposit underlying into SY
        let sy_token = standardized_yield::deposit(vault, underlying, ctx);

        // Step 2: Mint PT + YT from SY
        let (pt, yt) = yield_tokenizer::mint_py(config, sy_token, clock, ctx);

        let yt_amount = yield_tokenizer::yt_amount(&yt);
        assert!(yt_amount >= min_yt_amount, ESlippageExceeded);

        // Step 3: Sell PT on AMM for SY (user recovers most of their capital)
        let sy_recovered = rate_market::swap_pt_for_sy(pool, vault, config, pt, 0, clock, ctx);

        // Transfer recovered SY to user
        sui::transfer::public_transfer(sy_recovered, ctx.sender());

        // The user now has:
        // - YT (leveraged yield exposure) → transferred to user
        // - Recovered SY from selling PT → transferred to user
        // Net cost = underlying_amount - sy_recovered (the "premium" for yield exposure)

        let leverage = crux::amm_math::yt_leverage(
            crux::amm_math::pt_price_from_rate(
                rate_market::current_implied_rate(pool),
                rate_market::pool_maturity(pool) - clock.timestamp_ms(),
            )
        );

        event::emit(LeveragedYieldEntry {
            user: ctx.sender(),
            underlying_amount,
            yt_received: yt_amount,
            leverage_factor: leverage,
            maturity_ms: rate_market::pool_maturity(pool),
        });

        // Transfer YT to user
        sui::transfer::public_transfer(yt, ctx.sender());
    }

    // ===== Yield Management =====

    /// Claim yield from a YT position and optionally compound by buying more YT.
    public fun claim_yield<T>(
        config: &mut YieldMarketConfig<T>,
        yt: &mut YT<T>,
        ctx: &mut TxContext,
    ): u64 {
        yield_tokenizer::claim_yield(config, yt, ctx)
    }

    // ===== Position Information =====

    /// Calculate the current value of a PT position in underlying terms.
    /// Before maturity: based on AMM price.
    /// After maturity: based on settlement rate.
    public fun pt_value_in_sy<T>(
        config: &YieldMarketConfig<T>,
        pool: &YieldPool<T>,
        pt_amount: u64,
        clock: &Clock,
    ): u64 {
        if (yield_tokenizer::is_expired(config)) {
            // Post-maturity: PT redeems at settlement rate
            let settlement_index = yield_tokenizer::settlement_py_index(config);
            let initial_index = yield_tokenizer::initial_py_index(config);
            crux::fixed_point::from_wad(
                crux::fixed_point::wad_div(
                    crux::fixed_point::wad_mul(
                        crux::fixed_point::to_wad(pt_amount),
                        initial_index,
                    ),
                    settlement_index,
                )
            )
        } else {
            // Pre-maturity: based on AMM price
            rate_market::preview_swap_pt_for_sy(pool, pt_amount, clock)
        }
    }

    /// Calculate pending yield for a YT position
    public fun pending_yield<T>(
        config: &YieldMarketConfig<T>,
        yt: &YT<T>,
    ): u64 {
        yield_tokenizer::pending_yield(config, yt)
    }
}
