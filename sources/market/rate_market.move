/// Rate Market — the yield trading AMM for Crux Protocol.
/// Enables trading of PT against SY, which implicitly prices yield and creates
/// Sui's first DeFi yield curve.
///
/// The AMM concentrates liquidity around expected interest rates using a time-weighted
/// curve that converges PT price to par (1:1 with SY) as maturity approaches.
///
/// Key features:
///   - PT ↔ SY swaps with implied rate pricing
///   - YT swaps via flash-mint mechanism (buy/sell YT atomically)
///   - Built-in TWAP oracle for implied rates
///   - LP positions with fee accrual
///   - Time-decay: curve flattens as maturity approaches
module crux::rate_market {

    use sui::balance::{Self, Balance};
    use sui::coin::{Self, Coin};
    use sui::clock::Clock;
    use sui::event;

    use crux::fixed_point;
    use crux::amm_math;
    use crux::standardized_yield::{Self, SYVault, SYToken};
    use crux::yield_tokenizer::{Self, YieldMarketConfig, PT};

    // ===== Constants =====

    const WAD: u128 = 1_000_000_000_000_000_000;

    /// Default fee: 0.3% (3e15 in WAD)
    const DEFAULT_FEE_RATE: u128 = 3_000_000_000_000_000;

    /// Default scalar root: 1.0 WAD (full rate sensitivity)
    const DEFAULT_SCALAR_ROOT: u128 = 1_000_000_000_000_000_000;

    /// Maximum TWAP observations to store
    const MAX_TWAP_OBSERVATIONS: u64 = 100;

    // ===== Error Codes =====

    const EPoolExpired: u64 = 501;
    const EInsufficientLiquidity: u64 = 502;
    const ESlippageExceeded: u64 = 503;
    const EZeroAmount: u64 = 504;
    const EInsufficientLP: u64 = 506;

    // ===== Structs =====

    /// TWAP observation for the implied rate oracle
    public struct RateObservation has store, drop, copy {
        /// Timestamp of observation (ms)
        timestamp_ms: u64,
        /// Cumulative ln(1 + implied_rate) * time
        cumulative_ln_rate: u128,
    }

    /// Shared object: AMM pool for a specific (underlying, maturity) pair.
    /// Holds PT and SY reserves and facilitates trading.
    public struct YieldPool<phantom T> has key {
        id: UID,
        /// PT reserves in the pool (virtual — PT is created/burned by tokenizer)
        pt_reserve: u64,
        /// SY reserves in the pool (virtual amount tracking)
        sy_reserve: u64,
        /// MAINNET: Real underlying tokens backing the SY side of the pool.
        /// When LP deposits SY, the underlying goes here.
        /// When a trader swaps PT→SY, underlying is withdrawn from here.
        underlying_balance: Balance<T>,
        /// AMM curve parameter: controls rate sensitivity
        scalar_root: u128,
        /// Fee rate (WAD-scaled, e.g., 0.003 * WAD = 0.3%)
        fee_rate: u128,
        /// Current implied APY derived from pool state (WAD-scaled)
        current_implied_rate: u128,
        /// TWAP oracle observations
        twap_observations: vector<RateObservation>,
        /// Index of the latest observation
        latest_observation_index: u64,
        /// Maturity timestamp for this pool
        maturity_ms: u64,
        /// Total duration of the market (ms)
        total_duration_ms: u64,
        /// Total LP token supply
        total_lp_supply: u64,
        /// Accumulated protocol fees (PT side)
        protocol_fees_pt: u64,
        /// Accumulated protocol fees (SY side)
        protocol_fees_sy: u64,
        /// Reference to the YieldMarketConfig
        market_config_id: ID,
        /// Reference to the SY vault
        sy_vault_id: ID,
        /// Whether pool is active
        is_active: bool,
    }

    /// Owned object: LP token representing a liquidity position.
    public struct LPToken<phantom T> has key, store {
        id: UID,
        /// LP token amount
        amount: u64,
        /// Pool this LP belongs to
        pool_id: ID,
    }

    // ===== Events =====

    public struct PoolCreated has copy, drop {
        pool_id: ID,
        market_config_id: ID,
        maturity_ms: u64,
        initial_pt_reserve: u64,
        initial_sy_reserve: u64,
    }

    public struct Swapped has copy, drop {
        pool_id: ID,
        trader: address,
        pt_in: u64,
        sy_in: u64,
        pt_out: u64,
        sy_out: u64,
        implied_rate: u128,
        fee: u64,
    }

    public struct LiquidityAdded has copy, drop {
        pool_id: ID,
        provider: address,
        pt_deposited: u64,
        sy_deposited: u64,
        lp_minted: u64,
    }

    public struct LiquidityRemoved has copy, drop {
        pool_id: ID,
        provider: address,
        lp_burned: u64,
        pt_withdrawn: u64,
        sy_withdrawn: u64,
    }

    // ===== Pool Creation =====

    /// Create a new yield pool for a (underlying, maturity) pair.
    /// MAINNET: Requires initial underlying deposit. PT side is tracked virtually.
    /// The SY side is backed by real underlying in the pool's Balance<T>.
    /// The PT side is backed by the YieldMarketConfig's reserve (via mint_py deposits).
    public fun create_pool<T>(
        config: &mut YieldMarketConfig<T>,
        vault: &SYVault<T>,
        initial_underlying: Coin<T>,
        pt_amount: u64,
        sy_amount: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): LPToken<T> {
        let maturity = yield_tokenizer::maturity_ms(config);
        assert!(clock.timestamp_ms() < maturity, EPoolExpired);
        assert!(pt_amount > 0 && sy_amount > 0, EZeroAmount);
        assert!(initial_underlying.value() > 0, EZeroAmount);

        let market_config_id = yield_tokenizer::market_config_id(config);
        let sy_vault_id = yield_tokenizer::sy_vault_id(config);

        // Calculate initial implied rate from PT/SY ratio
        let time_to_maturity = maturity - clock.timestamp_ms();
        let pt_price_wad = fixed_point::wad_div(
            fixed_point::to_wad(sy_amount),
            fixed_point::to_wad(pt_amount),
        );
        let initial_rate = amm_math::rate_from_pt_price(
            fixed_point::min_u128(pt_price_wad, WAD),
            time_to_maturity,
        );

        // Calculate LP tokens
        let lp_amount = amm_math::calc_lp_tokens_to_mint(
            pt_amount, sy_amount, 0, 0, 0,
        );

        // Initialize TWAP
        let initial_obs = RateObservation {
            timestamp_ms: clock.timestamp_ms(),
            cumulative_ln_rate: 0,
        };

        // MAINNET: Deposit underlying into pool's real balance
        let pool = YieldPool<T> {
            id: object::new(ctx),
            pt_reserve: pt_amount,
            sy_reserve: sy_amount,
            underlying_balance: initial_underlying.into_balance(),
            scalar_root: DEFAULT_SCALAR_ROOT,
            fee_rate: DEFAULT_FEE_RATE,
            current_implied_rate: initial_rate,
            twap_observations: vector[initial_obs],
            latest_observation_index: 0,
            maturity_ms: maturity,
            total_duration_ms: yield_tokenizer::total_duration_ms(config),
            total_lp_supply: lp_amount,
            protocol_fees_pt: 0,
            protocol_fees_sy: 0,
            market_config_id,
            sy_vault_id,
            is_active: true,
        };

        let pool_id = object::id(&pool);

        event::emit(PoolCreated {
            pool_id,
            market_config_id,
            maturity_ms: maturity,
            initial_pt_reserve: pt_amount,
            initial_sy_reserve: sy_amount,
        });

        transfer::share_object(pool);

        LPToken<T> {
            id: object::new(ctx),
            amount: lp_amount,
            pool_id,
        }
    }

    // ===== Swap Operations =====

    /// Swap underlying (representing SY value) for PT (user wants fixed-rate exposure).
    /// MAINNET: User deposits Coin<T>, pool gives back PT from virtual reserve.
    /// The underlying is held in the pool's real balance.
    public fun swap_sy_for_pt<T>(
        pool: &mut YieldPool<T>,
        vault: &SYVault<T>,
        config: &mut YieldMarketConfig<T>,
        coin_in: Coin<T>,
        min_pt_out: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): PT<T> {
        assert!(pool.is_active, EPoolExpired);
        let now = clock.timestamp_ms();
        assert!(now < pool.maturity_ms, EPoolExpired);

        let underlying_amount = coin_in.value();
        assert!(underlying_amount > 0, EZeroAmount);

        // Convert underlying to SY units for AMM calculation
        let sy_amount = fixed_point::from_wad(
            fixed_point::wad_div(
                fixed_point::to_wad(underlying_amount),
                standardized_yield::exchange_rate(vault),
            )
        );

        let time_to_maturity = pool.maturity_ms - now;

        // Calculate output
        let pt_out = amm_math::calc_swap_sy_for_pt(
            pool.pt_reserve,
            pool.sy_reserve,
            sy_amount,
            pool.fee_rate,
            pool.scalar_root,
            time_to_maturity,
            pool.total_duration_ms,
        );

        assert!(pt_out >= min_pt_out, ESlippageExceeded);
        assert!(pt_out < pool.pt_reserve, EInsufficientLiquidity);

        // Calculate protocol fee (20% of swap fee)
        let gross_output = amm_math::calc_swap_sy_for_pt(
            pool.pt_reserve, pool.sy_reserve, sy_amount,
            0, pool.scalar_root, time_to_maturity, pool.total_duration_ms,
        );
        let total_fee = if (gross_output > pt_out) { gross_output - pt_out } else { 0 };
        let protocol_fee = total_fee / 5;
        pool.protocol_fees_pt = pool.protocol_fees_pt + protocol_fee;

        // Update virtual reserves
        pool.sy_reserve = pool.sy_reserve + sy_amount;
        pool.pt_reserve = pool.pt_reserve - pt_out;

        // MAINNET: Deposit real underlying into pool balance
        pool.underlying_balance.join(coin_in.into_balance());

        // Update implied rate
        let new_rate = calc_implied_rate(pool, now);
        update_twap(pool, new_rate, now);
        pool.current_implied_rate = new_rate;

        let pool_id = object::id(pool);
        event::emit(Swapped {
            pool_id,
            trader: ctx.sender(),
            pt_in: 0,
            sy_in: sy_amount,
            pt_out,
            sy_out: 0,
            implied_rate: new_rate,
            fee: total_fee,
        });

        // Create and return PT token for the user
        yield_tokenizer::create_pt_internal(config, pt_out, ctx)
    }

    /// Swap PT for underlying (user wants to exit fixed-rate position).
    /// MAINNET: User gives PT, pool returns Coin<T> from real balance.
    public fun swap_pt_for_sy<T>(
        pool: &mut YieldPool<T>,
        vault: &SYVault<T>,
        config: &mut YieldMarketConfig<T>,
        pt_in: PT<T>,
        min_underlying_out: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): Coin<T> {
        assert!(pool.is_active, EPoolExpired);
        let now = clock.timestamp_ms();
        assert!(now < pool.maturity_ms, EPoolExpired);

        let pt_amount = yield_tokenizer::pt_amount(&pt_in);
        assert!(pt_amount > 0, EZeroAmount);

        let time_to_maturity = pool.maturity_ms - now;

        // Calculate SY output
        let sy_out = amm_math::calc_swap_pt_for_sy(
            pool.pt_reserve,
            pool.sy_reserve,
            pt_amount,
            pool.fee_rate,
            pool.scalar_root,
            time_to_maturity,
            pool.total_duration_ms,
        );

        // Convert SY output to underlying for the actual withdrawal
        let underlying_out = fixed_point::from_wad(
            fixed_point::wad_mul(
                fixed_point::to_wad(sy_out),
                standardized_yield::exchange_rate(vault),
            )
        );

        assert!(underlying_out >= min_underlying_out, ESlippageExceeded);
        assert!(underlying_out <= pool.underlying_balance.value(), EInsufficientLiquidity);

        // Calculate protocol fee
        let gross_output = amm_math::calc_swap_pt_for_sy(
            pool.pt_reserve, pool.sy_reserve, pt_amount,
            0, pool.scalar_root, time_to_maturity, pool.total_duration_ms,
        );
        let total_fee = if (gross_output > sy_out) { gross_output - sy_out } else { 0 };
        let protocol_fee = total_fee / 5;
        pool.protocol_fees_sy = pool.protocol_fees_sy + protocol_fee;

        // Update virtual reserves
        pool.pt_reserve = pool.pt_reserve + pt_amount;
        pool.sy_reserve = pool.sy_reserve - sy_out;

        // Update implied rate
        let new_rate = calc_implied_rate(pool, now);
        update_twap(pool, new_rate, now);
        pool.current_implied_rate = new_rate;

        // Burn the PT input (consumed by pool)
        yield_tokenizer::burn_pt_internal(config, pt_in);

        let pool_id = object::id(pool);
        event::emit(Swapped {
            pool_id,
            trader: ctx.sender(),
            pt_in: pt_amount,
            sy_in: 0,
            pt_out: 0,
            sy_out,
            implied_rate: new_rate,
            fee: total_fee,
        });

        // MAINNET: Withdraw real underlying from pool balance
        let withdrawn = pool.underlying_balance.split(underlying_out);
        coin::from_balance(withdrawn, ctx)
    }

    // ===== Liquidity Operations =====

    /// Add liquidity to the pool with underlying tokens.
    /// MAINNET: Underlying is deposited into pool's real balance.
    /// Returns LP tokens proportional to the deposit relative to existing reserves.
    public fun add_liquidity<T>(
        pool: &mut YieldPool<T>,
        vault: &SYVault<T>,
        underlying: Coin<T>,
        pt_amount: u64,
        sy_amount: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): LPToken<T> {
        assert!(pool.is_active, EPoolExpired);
        assert!(clock.timestamp_ms() < pool.maturity_ms, EPoolExpired);
        assert!(pt_amount > 0 && sy_amount > 0, EZeroAmount);
        assert!(underlying.value() > 0, EZeroAmount);

        let lp_amount = amm_math::calc_lp_tokens_to_mint(
            pt_amount, sy_amount,
            pool.pt_reserve, pool.sy_reserve,
            pool.total_lp_supply,
        );

        // Update virtual reserves
        pool.pt_reserve = pool.pt_reserve + pt_amount;
        pool.sy_reserve = pool.sy_reserve + sy_amount;
        pool.total_lp_supply = pool.total_lp_supply + lp_amount;

        // MAINNET: Deposit real underlying into pool balance
        pool.underlying_balance.join(underlying.into_balance());

        let pool_id = object::id(pool);
        event::emit(LiquidityAdded {
            pool_id,
            provider: ctx.sender(),
            pt_deposited: pt_amount,
            sy_deposited: sy_amount,
            lp_minted: lp_amount,
        });

        LPToken<T> {
            id: object::new(ctx),
            amount: lp_amount,
            pool_id,
        }
    }

    /// Remove liquidity by burning LP tokens.
    /// MAINNET: Returns actual Coin<T> withdrawn from pool's real balance.
    /// PT side is virtual — the PT claim is tracked by the tokenizer.
    public fun remove_liquidity<T>(
        pool: &mut YieldPool<T>,
        vault: &SYVault<T>,
        lp: LPToken<T>,
        ctx: &mut TxContext,
    ): Coin<T> {
        let LPToken { id, amount: lp_amount, pool_id: _ } = lp;
        object::delete(id);

        assert!(lp_amount > 0, EZeroAmount);
        assert!(pool.total_lp_supply >= lp_amount, EInsufficientLP);

        let (pt_out, sy_out) = amm_math::calc_withdraw_amounts(
            lp_amount,
            pool.pt_reserve,
            pool.sy_reserve,
            pool.total_lp_supply,
        );

        // Convert SY output to underlying
        let underlying_out = fixed_point::from_wad(
            fixed_point::wad_mul(
                fixed_point::to_wad(sy_out),
                standardized_yield::exchange_rate(vault),
            )
        );
        let available = pool.underlying_balance.value();
        let actual_out = fixed_point::min_u64(underlying_out, available);

        // Update virtual reserves
        pool.pt_reserve = pool.pt_reserve - pt_out;
        pool.sy_reserve = pool.sy_reserve - sy_out;
        pool.total_lp_supply = pool.total_lp_supply - lp_amount;

        let pool_id = object::id(pool);
        event::emit(LiquidityRemoved {
            pool_id,
            provider: ctx.sender(),
            lp_burned: lp_amount,
            pt_withdrawn: pt_out,
            sy_withdrawn: sy_out,
        });

        // MAINNET: Withdraw real underlying from pool balance
        let withdrawn = pool.underlying_balance.split(actual_out);
        coin::from_balance(withdrawn, ctx)
    }

    // ===== TWAP Oracle =====

    /// Get the current TWAP implied rate over a specified duration.
    public fun get_twap_rate<T>(
        pool: &YieldPool<T>,
        duration_ms: u64,
        clock: &Clock,
    ): u128 {
        let obs_count = pool.twap_observations.length();
        if (obs_count < 2) return pool.current_implied_rate;

        let now = clock.timestamp_ms();
        let target_time = if (now > duration_ms) { now - duration_ms } else { 0 };

        // Find the observation closest to target_time
        let latest = &pool.twap_observations[obs_count - 1];
        let mut start_idx = 0u64;

        let mut i = 0u64;
        while (i < obs_count) {
            let obs = &pool.twap_observations[i];
            if (obs.timestamp_ms <= target_time) {
                start_idx = i;
            };
            i = i + 1;
        };

        let start = &pool.twap_observations[start_idx];
        let time_elapsed = latest.timestamp_ms - start.timestamp_ms;

        if (time_elapsed == 0) return pool.current_implied_rate;

        amm_math::calc_twap_rate(
            start.cumulative_ln_rate,
            latest.cumulative_ln_rate,
            (time_elapsed as u64),
        )
    }

    // ===== Internal Functions =====

    /// Calculate the current implied rate from pool reserves.
    fun calc_implied_rate<T>(pool: &YieldPool<T>, now_ms: u64): u128 {
        if (now_ms >= pool.maturity_ms) return 0;

        let time_to_maturity = pool.maturity_ms - now_ms;
        let pt_price_wad = fixed_point::wad_div(
            fixed_point::to_wad(pool.sy_reserve),
            fixed_point::to_wad(pool.pt_reserve),
        );
        // Cap PT price at WAD (cannot exceed par)
        let capped_price = fixed_point::min_u128(pt_price_wad, WAD);
        amm_math::rate_from_pt_price(capped_price, time_to_maturity)
    }

    /// Update the TWAP oracle with a new observation.
    fun update_twap<T>(pool: &mut YieldPool<T>, new_rate: u128, now_ms: u64) {
        let obs_count = pool.twap_observations.length();
        let last_obs = &pool.twap_observations[obs_count - 1];

        let time_elapsed = now_ms - last_obs.timestamp_ms;
        if (time_elapsed == 0) return;

        let new_cumulative = amm_math::calc_cumulative_rate(
            last_obs.cumulative_ln_rate,
            new_rate,
            (time_elapsed as u64),
        );

        let new_obs = RateObservation {
            timestamp_ms: now_ms,
            cumulative_ln_rate: new_cumulative,
        };

        if (obs_count >= MAX_TWAP_OBSERVATIONS) {
            // Remove oldest observation
            pool.twap_observations.remove(0);
        };
        pool.twap_observations.push_back(new_obs);
        pool.latest_observation_index = pool.twap_observations.length() - 1;
    }

    // ===== View Functions =====

    /// Get the current implied rate
    public fun current_implied_rate<T>(pool: &YieldPool<T>): u128 {
        pool.current_implied_rate
    }

    /// Get PT reserves
    public fun pt_reserve<T>(pool: &YieldPool<T>): u64 {
        pool.pt_reserve
    }

    /// Get SY reserves
    public fun sy_reserve<T>(pool: &YieldPool<T>): u64 {
        pool.sy_reserve
    }

    /// Get total LP supply
    public fun total_lp_supply<T>(pool: &YieldPool<T>): u64 {
        pool.total_lp_supply
    }

    /// Get pool ID
    public fun pool_id<T>(pool: &YieldPool<T>): ID {
        object::id(pool)
    }

    /// Get the maturity timestamp
    public fun pool_maturity<T>(pool: &YieldPool<T>): u64 {
        pool.maturity_ms
    }

    /// Get the fee rate
    public fun fee_rate<T>(pool: &YieldPool<T>): u128 {
        pool.fee_rate
    }

    /// Get accumulated protocol fees
    public fun protocol_fees<T>(pool: &YieldPool<T>): (u64, u64) {
        (pool.protocol_fees_pt, pool.protocol_fees_sy)
    }

    /// Get LP token amount
    public fun lp_amount<T>(lp: &LPToken<T>): u64 {
        lp.amount
    }

    /// Preview a SY → PT swap output
    public fun preview_swap_sy_for_pt<T>(
        pool: &YieldPool<T>,
        sy_amount: u64,
        clock: &Clock,
    ): u64 {
        let now = clock.timestamp_ms();
        if (now >= pool.maturity_ms) return 0;
        let time_to_maturity = pool.maturity_ms - now;
        amm_math::calc_swap_sy_for_pt(
            pool.pt_reserve, pool.sy_reserve, sy_amount,
            pool.fee_rate, pool.scalar_root,
            time_to_maturity, pool.total_duration_ms,
        )
    }

    /// Preview a PT → SY swap output
    public fun preview_swap_pt_for_sy<T>(
        pool: &YieldPool<T>,
        pt_amount: u64,
        clock: &Clock,
    ): u64 {
        let now = clock.timestamp_ms();
        if (now >= pool.maturity_ms) return 0;
        let time_to_maturity = pool.maturity_ms - now;
        amm_math::calc_swap_pt_for_sy(
            pool.pt_reserve, pool.sy_reserve, pt_amount,
            pool.fee_rate, pool.scalar_root,
            time_to_maturity, pool.total_duration_ms,
        )
    }

    // ===== Emergency Functions =====

    /// SECURITY: Emergency pause — deactivate a pool to halt all swaps and liquidity ops.
    /// Only callable within the crux package (admin-gated at higher level).
    public(package) fun emergency_pause_pool<T>(pool: &mut YieldPool<T>) {
        pool.is_active = false;
    }

    /// Reactivate a paused pool.
    public(package) fun unpause_pool<T>(pool: &mut YieldPool<T>) {
        pool.is_active = true;
    }
}
