/// Maturity Vault — manages the lifecycle of maturity periods for Crux Protocol.
/// Provides a registry of all active and expired maturities, standard maturity
/// date management, and automated settlement coordination.
///
/// Standard maturity periods: 1 month, 3 months, 6 months, 1 year.
/// New maturities are created on a rolling basis as existing ones expire.
module crux::maturity_vault {

    use sui::clock::Clock;
    use sui::event;

    // ===== Constants =====

    /// Standard maturity durations in milliseconds
    const ONE_MONTH_MS: u64 = 2_629_800_000;    // ~30.4375 days
    const THREE_MONTHS_MS: u64 = 7_889_400_000;  // ~91.3125 days
    const SIX_MONTHS_MS: u64 = 15_778_800_000;   // ~182.625 days
    const ONE_YEAR_MS: u64 = 31_557_600_000;      // ~365.25 days

    // ===== Error Codes =====

    const EMaturityInPast: u64 = 800;
    const EDuplicateMaturity: u64 = 801;
    const EMaturityNotFound: u64 = 802;
    const ENotExpired: u64 = 803;

    // ===== Structs =====

    /// Admin capability for maturity management
    public struct MaturityAdminCap has key, store {
        id: UID,
    }

    /// Information about a specific maturity period
    public struct MaturityInfo has store, drop, copy {
        /// Maturity timestamp (ms)
        maturity_ms: u64,
        /// When this maturity was created
        created_ms: u64,
        /// Duration category (1=1mo, 3=3mo, 6=6mo, 12=1yr)
        duration_months: u8,
        /// Whether settlement has occurred
        is_settled: bool,
        /// The market config ID (if a yield market exists for this maturity)
        market_config_id: ID,
    }

    /// Shared object: registry of all maturities across the protocol.
    public struct MaturityRegistry has key {
        id: UID,
        /// Active (not yet expired) maturities, sorted by timestamp
        active_maturities: vector<MaturityInfo>,
        /// Settled maturities (kept for historical reference)
        settled_maturities: vector<MaturityInfo>,
    }

    // ===== Events =====

    public struct MaturityCreated has copy, drop {
        maturity_ms: u64,
        duration_months: u8,
        created_ms: u64,
    }

    public struct MaturitySettled has copy, drop {
        maturity_ms: u64,
        settled_ms: u64,
    }

    // ===== Init =====

    /// Initialize the maturity registry and admin cap.
    fun init(ctx: &mut TxContext) {
        transfer::transfer(
            MaturityAdminCap { id: object::new(ctx) },
            ctx.sender(),
        );

        transfer::share_object(MaturityRegistry {
            id: object::new(ctx),
            active_maturities: vector[],
            settled_maturities: vector[],
        });
    }

    // ===== Maturity Management =====

    /// Create standard maturities from the current time.
    /// Generates 1mo, 3mo, 6mo, and 1yr maturities.
    public fun create_standard_maturities(
        _admin: &MaturityAdminCap,
        registry: &mut MaturityRegistry,
        market_config_id: ID,
        clock: &Clock,
    ) {
        let now = clock.timestamp_ms();

        create_maturity_internal(registry, now + ONE_MONTH_MS, 1, now, market_config_id);
        create_maturity_internal(registry, now + THREE_MONTHS_MS, 3, now, market_config_id);
        create_maturity_internal(registry, now + SIX_MONTHS_MS, 6, now, market_config_id);
        create_maturity_internal(registry, now + ONE_YEAR_MS, 12, now, market_config_id);
    }

    /// Create a custom maturity with a specific timestamp.
    public fun create_custom_maturity(
        _admin: &MaturityAdminCap,
        registry: &mut MaturityRegistry,
        maturity_ms: u64,
        duration_months: u8,
        market_config_id: ID,
        clock: &Clock,
    ) {
        let now = clock.timestamp_ms();
        assert!(maturity_ms > now, EMaturityInPast);
        create_maturity_internal(registry, maturity_ms, duration_months, now, market_config_id);
    }

    /// Mark a maturity as settled. Called after yield_tokenizer::settle_market.
    public fun mark_settled(
        registry: &mut MaturityRegistry,
        maturity_ms: u64,
        clock: &Clock,
    ) {
        let now = clock.timestamp_ms();
        assert!(now >= maturity_ms, ENotExpired);

        let mut found = false;
        let mut i = 0u64;
        let len = registry.active_maturities.length();

        while (i < len) {
            let info = &registry.active_maturities[i];
            if (info.maturity_ms == maturity_ms) {
                let mut settled_info = *info;
                settled_info.is_settled = true;
                registry.settled_maturities.push_back(settled_info);
                registry.active_maturities.remove(i);
                found = true;

                event::emit(MaturitySettled {
                    maturity_ms,
                    settled_ms: now,
                });
                break
            };
            i = i + 1;
        };

        assert!(found, EMaturityNotFound);
    }

    // ===== Internal =====

    fun create_maturity_internal(
        registry: &mut MaturityRegistry,
        maturity_ms: u64,
        duration_months: u8,
        now: u64,
        market_config_id: ID,
    ) {
        // Check for duplicate
        let len = registry.active_maturities.length();
        let mut i = 0u64;
        while (i < len) {
            assert!(
                registry.active_maturities[i].maturity_ms != maturity_ms,
                EDuplicateMaturity,
            );
            i = i + 1;
        };

        let info = MaturityInfo {
            maturity_ms,
            created_ms: now,
            duration_months,
            is_settled: false,
            market_config_id,
        };

        registry.active_maturities.push_back(info);

        event::emit(MaturityCreated {
            maturity_ms,
            duration_months,
            created_ms: now,
        });
    }

    // ===== View Functions =====

    /// Get all active (non-expired) maturities
    public fun active_maturities(registry: &MaturityRegistry): &vector<MaturityInfo> {
        &registry.active_maturities
    }

    /// Get the number of active maturities
    public fun active_count(registry: &MaturityRegistry): u64 {
        registry.active_maturities.length()
    }

    /// Get upcoming maturities that are expiring within a time window
    public fun expiring_within(
        registry: &MaturityRegistry,
        window_ms: u64,
        clock: &Clock,
    ): vector<u64> {
        let now = clock.timestamp_ms();
        let deadline = now + window_ms;
        let mut result = vector[];

        let len = registry.active_maturities.length();
        let mut i = 0u64;
        while (i < len) {
            let info = &registry.active_maturities[i];
            if (info.maturity_ms <= deadline && info.maturity_ms > now) {
                result.push_back(info.maturity_ms);
            };
            i = i + 1;
        };

        result
    }

    // ===== Test Helpers =====

    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) {
        init(ctx);
    }

    /// Get the standard maturity durations in ms
    public fun standard_durations(): vector<u64> {
        vector[ONE_MONTH_MS, THREE_MONTHS_MS, SIX_MONTHS_MS, ONE_YEAR_MS]
    }
}
