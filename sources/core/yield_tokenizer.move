/// Yield Tokenizer — the core engine of Crux Protocol.
/// Splits Standardized Yield (SY) tokens into Principal Tokens (PT) and Yield Tokens (YT).
///
/// Key mechanics:
///   - 1 SY can be split into 1 PT + 1 YT (at current PY index)
///   - PT is redeemable for underlying at maturity (fixed-rate claim)
///   - YT accrues all variable yield until maturity (leveraged yield exposure)
///   - Pre-maturity: PT + YT can be combined back into SY
///   - Post-maturity: PT redeems at the settlement rate; YT expires (yield already claimed)
///
/// The PY index tracks the SY exchange rate and is used to calculate yield distribution.
module crux::yield_tokenizer {

    use sui::balance::{Self, Balance};
    use sui::coin::{Self, Coin};
    use sui::clock::Clock;
    use sui::event;

    use crux::fixed_point;
    use crux::standardized_yield::{Self, AdminCap, SYVault, SYToken};

    // ===== Constants =====

    const WAD: u128 = 1_000_000_000_000_000_000;

    // ===== Error Codes =====

    const EMarketExpired: u64 = 300;
    const EMarketNotExpired: u64 = 301;
    const EZeroAmount: u64 = 302;
    const EMismatchedAmounts: u64 = 303;
    const EMismatchedMarket: u64 = 304;
    const EAlreadySettled: u64 = 305;
    const ENotSettled: u64 = 306;
    const EKeeperStillActive: u64 = 307;

    /// If keeper is offline for more than 2 hours past maturity,
    /// anyone can trigger permissionless settlement with current on-chain rate.
    const KEEPER_TIMEOUT_MS: u64 = 7_200_000; // 2 hours

    // ===== Structs =====

    /// Shared object: configuration for a (underlying, maturity) pair.
    /// One YieldMarketConfig per supported asset per maturity date.
    public struct YieldMarketConfig<phantom T> has key {
        id: UID,
        /// Unix timestamp (ms) when this market matures
        maturity_ms: u64,
        /// PY index at market creation (snapshot of SY exchange rate at inception)
        initial_py_index: u128,
        /// Current PY index (tracks SY exchange rate, monotonically non-decreasing)
        current_py_index: u128,
        /// PY index at settlement (set when maturity is reached)
        settlement_py_index: u128,
        /// Whether maturity has been reached and settled
        is_expired: bool,
        /// Reference to the parent SY vault
        sy_vault_id: ID,
        /// Global interest index for yield distribution (WAD-scaled)
        /// Tracks cumulative yield per YT unit
        global_interest_index: u128,
        /// Total PT supply outstanding
        total_pt_supply: u64,
        /// Total YT supply outstanding
        total_yt_supply: u64,
        /// SY tokens held as yield reserve (accrued yield awaiting claim)
        yield_reserve_sy: u64,
        /// Total duration of this market in ms (maturity_ms - creation_time)
        total_duration_ms: u64,
        /// Last keeper heartbeat timestamp (ms). Used for fallback settlement.
        last_keeper_heartbeat_ms: u64,
        /// MAINNET: Real underlying token reserve backing all PT+YT.
        /// When users mint PT+YT, underlying is deposited here.
        /// When users redeem, underlying is withdrawn from here.
        underlying_reserve: Balance<T>,
    }

    /// Owned object: Principal Token.
    /// Represents a claim on the underlying at maturity.
    /// Buying PT at a discount = locking in a fixed yield.
    public struct PT<phantom T> has key, store {
        id: UID,
        /// Amount of PT (in underlying asset units at maturity)
        amount: u64,
        /// Maturity timestamp
        maturity_ms: u64,
        /// Reference to parent market config
        market_config_id: ID,
    }

    /// Owned object: Yield Token.
    /// Receives all variable yield from the underlying until maturity.
    /// Provides leveraged yield exposure.
    public struct YT<phantom T> has key, store {
        id: UID,
        /// Amount of YT (mirrors PT amount at minting)
        amount: u64,
        /// Maturity timestamp
        maturity_ms: u64,
        /// Reference to parent market config
        market_config_id: ID,
        /// User's interest index snapshot at time of acquisition.
        /// Used to calculate accrued yield: yield = amount * (global_index - user_index) / WAD
        user_interest_index: u128,
    }

    // ===== Events =====

    public struct MarketCreated has copy, drop {
        market_config_id: ID,
        sy_vault_id: ID,
        maturity_ms: u64,
        initial_py_index: u128,
    }

    public struct PYMinted has copy, drop {
        market_config_id: ID,
        minter: address,
        sy_consumed: u64,
        pt_minted: u64,
        yt_minted: u64,
    }

    public struct PYRedeemed has copy, drop {
        market_config_id: ID,
        redeemer: address,
        pt_burned: u64,
        yt_burned: u64,
        sy_returned: u64,
    }

    public struct PTRedeemedPostExpiry has copy, drop {
        market_config_id: ID,
        redeemer: address,
        pt_burned: u64,
        sy_returned: u64,
    }

    public struct YieldClaimed has copy, drop {
        market_config_id: ID,
        claimer: address,
        yt_amount: u64,
        yield_sy: u64,
    }

    public struct MarketSettled has copy, drop {
        market_config_id: ID,
        settlement_py_index: u128,
        maturity_ms: u64,
    }

    public struct PYIndexUpdated has copy, drop {
        market_config_id: ID,
        old_index: u128,
        new_index: u128,
    }

    // ===== Market Creation =====

    /// Create a new yield market for an asset type with a specific maturity date.
    /// SECURITY: Requires AdminCap to prevent unauthorized market creation.
    public fun create_market<T>(
        _admin: &AdminCap,
        vault: &SYVault<T>,
        maturity_ms: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): ID {
        let now = clock.timestamp_ms();
        assert!(maturity_ms > now, EMarketExpired);

        let initial_rate = standardized_yield::exchange_rate(vault);
        let sy_vault_id = standardized_yield::vault_id(vault);

        let config = YieldMarketConfig<T> {
            id: object::new(ctx),
            maturity_ms,
            initial_py_index: initial_rate,
            current_py_index: initial_rate,
            settlement_py_index: 0,
            is_expired: false,
            sy_vault_id,
            global_interest_index: WAD, // Starts at 1.0
            total_pt_supply: 0,
            total_yt_supply: 0,
            yield_reserve_sy: 0,
            total_duration_ms: maturity_ms - now,
            last_keeper_heartbeat_ms: now,
            underlying_reserve: balance::zero<T>(),
        };

        let config_id = object::id(&config);

        event::emit(MarketCreated {
            market_config_id: config_id,
            sy_vault_id,
            maturity_ms,
            initial_py_index: initial_rate,
        });

        transfer::share_object(config);
        config_id
    }

    // ===== Core Operations =====

    /// Mint PT + YT by depositing underlying tokens directly.
    /// The underlying is held in the config's real reserve.
    /// SY amount = underlying / exchange_rate. 1 SY → 1 PT + 1 YT.
    /// Returns (PT, YT) tokens to the caller.
    public fun mint_py<T>(
        config: &mut YieldMarketConfig<T>,
        vault: &SYVault<T>,
        coin: Coin<T>,
        clock: &Clock,
        ctx: &mut TxContext,
    ): (PT<T>, YT<T>) {
        // SECURITY: Block minting if the vault is paused (emergency)
        assert!(!standardized_yield::is_paused(vault), 207);
        assert!(!config.is_expired, EMarketExpired);
        assert!(clock.timestamp_ms() < config.maturity_ms, EMarketExpired);

        let underlying_amount = coin.value();
        assert!(underlying_amount > 0, EZeroAmount);

        // Convert underlying to SY units using vault exchange rate
        let sy_amount = fixed_point::from_wad(
            fixed_point::wad_div(
                fixed_point::to_wad(underlying_amount),
                standardized_yield::exchange_rate(vault),
            )
        );
        assert!(sy_amount > 0, EZeroAmount);

        let market_config_id = object::id(config);

        // MAINNET: Deposit underlying into the config's real reserve
        config.underlying_reserve.join(coin.into_balance());

        config.total_pt_supply = config.total_pt_supply + sy_amount;
        config.total_yt_supply = config.total_yt_supply + sy_amount;

        event::emit(PYMinted {
            market_config_id,
            minter: ctx.sender(),
            sy_consumed: sy_amount,
            pt_minted: sy_amount,
            yt_minted: sy_amount,
        });

        let pt = PT<T> {
            id: object::new(ctx),
            amount: sy_amount,
            maturity_ms: config.maturity_ms,
            market_config_id,
        };

        let yt = YT<T> {
            id: object::new(ctx),
            amount: sy_amount,
            maturity_ms: config.maturity_ms,
            market_config_id,
            user_interest_index: config.global_interest_index,
        };

        (pt, yt)
    }

    /// Redeem PT + YT back to underlying before maturity.
    /// Requires equal amounts of PT and YT from the same market.
    /// MAINNET: Returns actual Coin<T> withdrawn from the config's reserve.
    public fun redeem_py_pre_expiry<T>(
        config: &mut YieldMarketConfig<T>,
        vault: &SYVault<T>,
        pt: PT<T>,
        yt: YT<T>,
        ctx: &mut TxContext,
    ): Coin<T> {
        assert!(!config.is_expired, EMarketExpired);

        let PT { id: pt_id, amount: pt_amount, maturity_ms: _, market_config_id: pt_market } = pt;
        let YT { id: yt_id, amount: yt_amount, maturity_ms: _, market_config_id: yt_market, user_interest_index: _ } = yt;

        assert!(pt_market == object::id(config), EMismatchedMarket);
        assert!(yt_market == object::id(config), EMismatchedMarket);
        assert!(pt_amount == yt_amount, EMismatchedAmounts);
        assert!(pt_amount > 0, EZeroAmount);

        object::delete(pt_id);
        object::delete(yt_id);

        // Update supply
        config.total_pt_supply = config.total_pt_supply - pt_amount;
        config.total_yt_supply = config.total_yt_supply - yt_amount;

        // Convert SY amount back to underlying: underlying = sy * exchange_rate
        let underlying_out = fixed_point::from_wad(
            fixed_point::wad_mul(
                fixed_point::to_wad(pt_amount),
                standardized_yield::exchange_rate(vault),
            )
        );

        // Cap at available reserve to prevent underflow
        let available = config.underlying_reserve.value();
        let actual_out = fixed_point::min_u64(underlying_out, available);

        let market_config_id = object::id(config);

        event::emit(PYRedeemed {
            market_config_id,
            redeemer: ctx.sender(),
            pt_burned: pt_amount,
            yt_burned: yt_amount,
            sy_returned: pt_amount,
        });

        // MAINNET: Withdraw actual underlying from reserve
        let withdrawn = config.underlying_reserve.split(actual_out);
        coin::from_balance(withdrawn, ctx)
    }

    /// Redeem PT after maturity for underlying.
    /// Post-expiry, only PT is needed (YT has expired, yield already claimable separately).
    /// MAINNET: Returns actual Coin<T> withdrawn from the config's reserve.
    public fun redeem_pt_post_expiry<T>(
        config: &mut YieldMarketConfig<T>,
        pt: PT<T>,
        ctx: &mut TxContext,
    ): Coin<T> {
        assert!(config.is_expired, EMarketNotExpired);
        assert!(config.settlement_py_index > 0, ENotSettled);

        let PT { id, amount, maturity_ms: _, market_config_id } = pt;
        assert!(market_config_id == object::id(config), EMismatchedMarket);
        assert!(amount > 0, EZeroAmount);

        object::delete(id);

        // PT redeems at settlement rate relative to initial rate.
        // SY amount = pt_amount * initial_py_index / settlement_py_index
        let sy_amount = fixed_point::from_wad(
            fixed_point::wad_div(
                fixed_point::wad_mul(fixed_point::to_wad(amount), config.initial_py_index),
                config.settlement_py_index,
            )
        );

        // Convert SY to underlying at settlement rate
        let underlying_out = fixed_point::from_wad(
            fixed_point::wad_mul(
                fixed_point::to_wad(sy_amount),
                config.settlement_py_index,
            )
        );

        let available = config.underlying_reserve.value();
        let actual_out = fixed_point::min_u64(underlying_out, available);

        config.total_pt_supply = config.total_pt_supply - amount;

        event::emit(PTRedeemedPostExpiry {
            market_config_id: object::id(config),
            redeemer: ctx.sender(),
            pt_burned: amount,
            sy_returned: sy_amount,
        });

        // MAINNET: Withdraw actual underlying from reserve
        let withdrawn = config.underlying_reserve.split(actual_out);
        coin::from_balance(withdrawn, ctx)
    }

    /// Claim accrued yield on a YT position.
    /// MAINNET: Returns actual Coin<T> withdrawn from the config's yield reserve.
    /// The YT is not consumed — user keeps it for future yield accrual.
    public fun claim_yield<T>(
        config: &mut YieldMarketConfig<T>,
        vault: &SYVault<T>,
        yt: &mut YT<T>,
        ctx: &mut TxContext,
    ): Coin<T> {
        assert!(yt.market_config_id == object::id(config), EMismatchedMarket);

        // Calculate accrued yield since last claim
        // yield = yt_amount * (global_interest_index - user_interest_index) / WAD
        let index_diff = if (config.global_interest_index > yt.user_interest_index) {
            config.global_interest_index - yt.user_interest_index
        } else {
            0
        };

        if (index_diff == 0) return coin::from_balance(balance::zero<T>(), ctx);

        let yield_amount = fixed_point::from_wad(
            fixed_point::wad_mul(
                fixed_point::to_wad(yt.amount),
                index_diff,
            )
        );

        // SECURITY: Cap at available reserve FIRST, then only advance index
        // proportionally to what was actually paid out.
        let actual_yield = if (yield_amount > config.yield_reserve_sy) {
            config.yield_reserve_sy
        } else {
            yield_amount
        };

        if (actual_yield == 0) return coin::from_balance(balance::zero<T>(), ctx);

        config.yield_reserve_sy = config.yield_reserve_sy - actual_yield;

        // SECURITY: Only advance user's index proportionally to amount actually paid.
        if (actual_yield == yield_amount) {
            yt.user_interest_index = config.global_interest_index;
        } else {
            let payout_ratio = fixed_point::wad_div(
                fixed_point::to_wad(actual_yield),
                fixed_point::to_wad(yield_amount),
            );
            let index_advance = fixed_point::wad_mul(index_diff, payout_ratio);
            yt.user_interest_index = yt.user_interest_index + index_advance;
        };

        // Convert SY yield to underlying amount
        let underlying_yield = fixed_point::from_wad(
            fixed_point::wad_mul(
                fixed_point::to_wad(actual_yield),
                standardized_yield::exchange_rate(vault),
            )
        );

        let available = config.underlying_reserve.value();
        let actual_underlying = fixed_point::min_u64(underlying_yield, available);

        event::emit(YieldClaimed {
            market_config_id: object::id(config),
            claimer: ctx.sender(),
            yt_amount: yt.amount,
            yield_sy: actual_yield,
        });

        // MAINNET: Withdraw actual underlying from reserve
        if (actual_underlying > 0) {
            let withdrawn = config.underlying_reserve.split(actual_underlying);
            coin::from_balance(withdrawn, ctx)
        } else {
            coin::from_balance(balance::zero<T>(), ctx)
        }
    }

    // ===== Index Management =====

    /// Update the PY index from the current SY exchange rate.
    /// Called by keeper bot or opportunistically on user actions.
    /// This is how yield "flows" to YT holders.
    public fun update_py_index<T>(
        config: &mut YieldMarketConfig<T>,
        vault: &SYVault<T>,
        clock: &Clock,
    ) {
        if (config.is_expired) return;

        let new_rate = standardized_yield::exchange_rate(vault);
        if (new_rate <= config.current_py_index) return;

        let old_index = config.current_py_index;

        // Calculate new yield generated
        // yield_per_sy = (new_rate - old_rate) / old_rate
        let yield_per_sy = fixed_point::wad_div(
            new_rate - old_index,
            old_index,
        );

        // Update global interest index
        // global_interest_index += yield_per_sy (this is additive per unit of YT)
        config.global_interest_index = config.global_interest_index + yield_per_sy;

        // Calculate total yield generated for the reserve
        // total_yield_sy = total_yt_supply * yield_per_sy / WAD
        let total_yield_sy = fixed_point::from_wad(
            fixed_point::wad_mul(
                fixed_point::to_wad(config.total_yt_supply),
                yield_per_sy,
            )
        );
        config.yield_reserve_sy = config.yield_reserve_sy + total_yield_sy;

        config.current_py_index = new_rate;

        event::emit(PYIndexUpdated {
            market_config_id: object::id(config),
            old_index,
            new_index: new_rate,
        });

        // Update keeper heartbeat — proves keeper is alive
        config.last_keeper_heartbeat_ms = clock.timestamp_ms();
    }

    /// Settle the market at maturity (admin path — preferred).
    /// SECURITY: Requires AdminCap. Keeper should call update_py_index first to
    /// ensure the final rate is current, then immediately settle.
    public fun settle_market<T>(
        _admin: &AdminCap,
        config: &mut YieldMarketConfig<T>,
        clock: &Clock,
    ) {
        assert!(clock.timestamp_ms() >= config.maturity_ms, EMarketNotExpired);
        assert!(!config.is_expired, EAlreadySettled);

        config.is_expired = true;
        config.settlement_py_index = config.current_py_index;

        event::emit(MarketSettled {
            market_config_id: object::id(config),
            settlement_py_index: config.settlement_py_index,
            maturity_ms: config.maturity_ms,
        });
    }

    /// Permissionless fallback settlement — anyone can call if the keeper has been
    /// offline for more than KEEPER_TIMEOUT_MS after maturity.
    /// Uses whatever the current on-chain PY index is (may be stale, but better
    /// than leaving the market unsettled indefinitely).
    public fun settle_market_fallback<T>(
        config: &mut YieldMarketConfig<T>,
        clock: &Clock,
    ) {
        let now = clock.timestamp_ms();
        assert!(now >= config.maturity_ms, EMarketNotExpired);
        assert!(!config.is_expired, EAlreadySettled);

        // Only allow fallback if keeper has been inactive for KEEPER_TIMEOUT_MS
        // past maturity. This gives the keeper time to do a proper settlement.
        let fallback_deadline = config.maturity_ms + KEEPER_TIMEOUT_MS;
        assert!(now >= fallback_deadline, EKeeperStillActive);

        config.is_expired = true;
        config.settlement_py_index = config.current_py_index;

        event::emit(MarketSettled {
            market_config_id: object::id(config),
            settlement_py_index: config.settlement_py_index,
            maturity_ms: config.maturity_ms,
        });
    }

    // ===== PT Operations =====

    /// Split a PT into two
    public fun split_pt<T>(
        pt: &mut PT<T>,
        split_amount: u64,
        ctx: &mut TxContext,
    ): PT<T> {
        assert!(pt.amount >= split_amount, EZeroAmount);
        pt.amount = pt.amount - split_amount;

        PT<T> {
            id: object::new(ctx),
            amount: split_amount,
            maturity_ms: pt.maturity_ms,
            market_config_id: pt.market_config_id,
        }
    }

    /// Merge two PTs (must be from same market)
    public fun merge_pt<T>(pt: &mut PT<T>, other: PT<T>) {
        let PT { id, amount, maturity_ms: _, market_config_id } = other;
        assert!(market_config_id == pt.market_config_id, EMismatchedMarket);
        object::delete(id);
        pt.amount = pt.amount + amount;
    }

    // ===== YT Operations =====

    /// Split a YT into two (yield claimed up to current point first)
    public fun split_yt<T>(
        yt: &mut YT<T>,
        split_amount: u64,
        ctx: &mut TxContext,
    ): YT<T> {
        assert!(yt.amount >= split_amount, EZeroAmount);
        yt.amount = yt.amount - split_amount;

        YT<T> {
            id: object::new(ctx),
            amount: split_amount,
            maturity_ms: yt.maturity_ms,
            market_config_id: yt.market_config_id,
            user_interest_index: yt.user_interest_index, // Same index snapshot
        }
    }

    /// Merge two YTs (must be from same market).
    /// SECURITY: Both YTs must have the same user_interest_index to prevent yield loss.
    /// Users must call claim_yield on both YTs before merging if indexes differ.
    public fun merge_yt<T>(yt: &mut YT<T>, other: YT<T>) {
        let YT { id, amount, maturity_ms: _, market_config_id, user_interest_index } = other;
        assert!(market_config_id == yt.market_config_id, EMismatchedMarket);
        assert!(user_interest_index == yt.user_interest_index, EMismatchedAmounts);
        object::delete(id);
        yt.amount = yt.amount + amount;
    }

    // ===== View Functions =====

    /// Get market maturity timestamp
    public fun maturity_ms<T>(config: &YieldMarketConfig<T>): u64 {
        config.maturity_ms
    }

    /// Get current PY index
    public fun current_py_index<T>(config: &YieldMarketConfig<T>): u128 {
        config.current_py_index
    }

    /// Get initial PY index
    public fun initial_py_index<T>(config: &YieldMarketConfig<T>): u128 {
        config.initial_py_index
    }

    /// Get settlement PY index (0 if not settled)
    public fun settlement_py_index<T>(config: &YieldMarketConfig<T>): u128 {
        config.settlement_py_index
    }

    /// Check if market is expired
    public fun is_expired<T>(config: &YieldMarketConfig<T>): bool {
        config.is_expired
    }

    /// Get total PT supply
    public fun total_pt_supply<T>(config: &YieldMarketConfig<T>): u64 {
        config.total_pt_supply
    }

    /// Get total YT supply
    public fun total_yt_supply<T>(config: &YieldMarketConfig<T>): u64 {
        config.total_yt_supply
    }

    /// Get total duration
    public fun total_duration_ms<T>(config: &YieldMarketConfig<T>): u64 {
        config.total_duration_ms
    }

    /// Get the market config ID
    public fun market_config_id<T>(config: &YieldMarketConfig<T>): ID {
        object::id(config)
    }

    /// Get SY vault ID for this market
    public fun sy_vault_id<T>(config: &YieldMarketConfig<T>): ID {
        config.sy_vault_id
    }

    /// Get PT amount
    public fun pt_amount<T>(pt: &PT<T>): u64 {
        pt.amount
    }

    /// Get PT maturity
    public fun pt_maturity<T>(pt: &PT<T>): u64 {
        pt.maturity_ms
    }

    /// Get PT market config ID
    public fun pt_market_config_id<T>(pt: &PT<T>): ID {
        pt.market_config_id
    }

    /// Get YT amount
    public fun yt_amount<T>(yt: &YT<T>): u64 {
        yt.amount
    }

    /// Get YT maturity
    public fun yt_maturity<T>(yt: &YT<T>): u64 {
        yt.maturity_ms
    }

    /// Get pending yield for a YT position
    public fun pending_yield<T>(config: &YieldMarketConfig<T>, yt: &YT<T>): u64 {
        let index_diff = if (config.global_interest_index > yt.user_interest_index) {
            config.global_interest_index - yt.user_interest_index
        } else {
            0
        };
        if (index_diff == 0) return 0;
        fixed_point::from_wad(
            fixed_point::wad_mul(fixed_point::to_wad(yt.amount), index_diff)
        )
    }

    /// Get the global interest index
    public fun global_interest_index<T>(config: &YieldMarketConfig<T>): u128 {
        config.global_interest_index
    }

    /// Get yield reserve
    public fun yield_reserve_sy<T>(config: &YieldMarketConfig<T>): u64 {
        config.yield_reserve_sy
    }

    /// Package-internal market creation (for permissionless_market module).
    /// Skips AdminCap requirement but is only callable within the crux package.
    public(package) fun create_market_internal<T>(
        vault: &SYVault<T>,
        maturity_ms: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): ID {
        let now = clock.timestamp_ms();
        assert!(maturity_ms > now, EMarketExpired);

        let initial_rate = standardized_yield::exchange_rate(vault);
        let sy_vault_id = standardized_yield::vault_id(vault);

        let config = YieldMarketConfig<T> {
            id: object::new(ctx),
            maturity_ms,
            initial_py_index: initial_rate,
            current_py_index: initial_rate,
            settlement_py_index: 0,
            is_expired: false,
            sy_vault_id,
            global_interest_index: WAD,
            total_pt_supply: 0,
            total_yt_supply: 0,
            yield_reserve_sy: 0,
            total_duration_ms: maturity_ms - now,
            last_keeper_heartbeat_ms: now,
            underlying_reserve: balance::zero<T>(),
        };

        let config_id = object::id(&config);

        event::emit(MarketCreated {
            market_config_id: config_id,
            sy_vault_id,
            maturity_ms,
            initial_py_index: initial_rate,
        });

        transfer::share_object(config);
        config_id
    }

    // ===== Reserve Management (Package-Internal) =====

    /// Deposit underlying into the config's reserve. Used by flash_mint repayment
    /// and pool operations that need to back PT+YT with real assets.
    public(package) fun deposit_to_reserve<T>(
        config: &mut YieldMarketConfig<T>,
        coin: Coin<T>,
    ) {
        config.underlying_reserve.join(coin.into_balance());
    }

    /// Withdraw underlying from the config's reserve. Used by pool operations.
    public(package) fun withdraw_from_reserve<T>(
        config: &mut YieldMarketConfig<T>,
        amount: u64,
        ctx: &mut TxContext,
    ): Coin<T> {
        let withdrawn = config.underlying_reserve.split(amount);
        coin::from_balance(withdrawn, ctx)
    }

    /// Get the underlying reserve balance.
    public fun reserve_balance<T>(config: &YieldMarketConfig<T>): u64 {
        config.underlying_reserve.value()
    }

    // ===== Package-Internal Functions (for flash_mint) =====

    /// Create a PT object. Only callable by modules within the crux package.
    public(package) fun create_pt_internal<T>(
        config: &mut YieldMarketConfig<T>,
        amount: u64,
        ctx: &mut TxContext,
    ): PT<T> {
        config.total_pt_supply = config.total_pt_supply + amount;
        PT<T> {
            id: object::new(ctx),
            amount,
            maturity_ms: config.maturity_ms,
            market_config_id: object::id(config),
        }
    }

    /// Create a YT object. Only callable by modules within the crux package.
    public(package) fun create_yt_internal<T>(
        config: &mut YieldMarketConfig<T>,
        amount: u64,
        ctx: &mut TxContext,
    ): YT<T> {
        config.total_yt_supply = config.total_yt_supply + amount;
        YT<T> {
            id: object::new(ctx),
            amount,
            maturity_ms: config.maturity_ms,
            market_config_id: object::id(config),
            user_interest_index: config.global_interest_index,
        }
    }

    /// Burn a PT object. Only callable by modules within the crux package.
    public(package) fun burn_pt_internal<T>(
        config: &mut YieldMarketConfig<T>,
        pt: PT<T>,
    ) {
        let PT { id, amount, maturity_ms: _, market_config_id: _ } = pt;
        object::delete(id);
        config.total_pt_supply = config.total_pt_supply - amount;
    }

    /// Burn a YT object. Only callable by modules within the crux package.
    public(package) fun burn_yt_internal<T>(
        config: &mut YieldMarketConfig<T>,
        yt: YT<T>,
    ) {
        let YT { id, amount, maturity_ms: _, market_config_id: _, user_interest_index: _ } = yt;
        object::delete(id);
        config.total_yt_supply = config.total_yt_supply - amount;
    }
}
