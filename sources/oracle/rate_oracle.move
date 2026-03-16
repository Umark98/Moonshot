/// Standalone TWAP oracle for implied yield rates in Crux Protocol.
/// Stores a rolling buffer of rate observations and exposes a time-weighted
/// average rate (TWAP) that external protocols can query as a public good.
module crux::rate_oracle {

    use sui::clock::Clock;
    use sui::event;
    use crux::amm_math;

    // ===== Error Codes =====

    /// Attempted to push an observation older than the last recorded one.
    const EStaleUpdate: u64 = 750;
    /// Attempted to push an observation before the minimum interval has elapsed.
    const ETooFrequent: u64 = 751;
    /// Not enough observations in the buffer to compute a TWAP.
    const EInsufficientHistory: u64 = 752;
    /// Requested TWAP duration is zero or exceeds available history.
    const EInvalidDuration: u64 = 753;

    // ===== Constants =====

    /// WAD — 1.0 in 18-decimal fixed-point (used by dependent modules).
    #[allow(unused_const)]
    const WAD: u128 = 1_000_000_000_000_000_000;

    /// Default rolling buffer size (~3 hours at 30-second intervals).
    const DEFAULT_MAX_OBSERVATIONS: u64 = 360;

    /// Default minimum time between two successive observations (30 seconds).
    const DEFAULT_MIN_INTERVAL_MS: u64 = 30_000;

    // ===== Structs =====

    /// A single price snapshot stored in the oracle buffer.
    public struct Observation has store, drop, copy {
        /// Wall-clock timestamp at which this observation was recorded (ms).
        timestamp_ms: u64,
        /// Spot implied annual rate at this timestamp, WAD-scaled.
        implied_rate_wad: u128,
        /// Cumulative ln(1 + rate) * time since oracle creation, used for TWAP.
        cumulative_rate: u128,
    }

    /// Shared oracle object for a specific yield market.
    /// Created once per market and shared so any caller can push or query.
    public struct RateOracleConfig has key {
        id: UID,
        /// ID of the YieldMarketConfig this oracle is attached to.
        market_config_id: ID,
        /// Rolling buffer of observations, oldest entry overwritten when full.
        observations: vector<Observation>,
        /// Maximum number of observations to retain (circular buffer capacity).
        max_observations: u64,
        /// Minimum milliseconds that must elapse between successive pushes.
        min_update_interval_ms: u64,
        /// Timestamp of the most recently recorded observation (ms).
        last_update_ms: u64,
    }

    // ===== Events =====

    /// Emitted each time a new observation is pushed to the oracle.
    public struct OracleUpdated has copy, drop {
        oracle_id: ID,
        implied_rate_wad: u128,
        timestamp_ms: u64,
    }

    /// Emitted when a new oracle object is created.
    public struct OracleCreated has copy, drop {
        oracle_id: ID,
        market_config_id: ID,
    }

    // ===== Public Functions =====

    /// Create a shared TWAP oracle for the given yield market and return its ID.
    /// The oracle starts with an empty observation buffer and default parameters.
    public fun create_oracle(
        market_config_id: ID,
        clock: &Clock,
        ctx: &mut TxContext,
    ): ID {
        let oracle = RateOracleConfig {
            id: object::new(ctx),
            market_config_id,
            observations: vector::empty(),
            max_observations: DEFAULT_MAX_OBSERVATIONS,
            min_update_interval_ms: DEFAULT_MIN_INTERVAL_MS,
            last_update_ms: clock.timestamp_ms(),
        };

        let oracle_id = object::id(&oracle);

        event::emit(OracleCreated {
            oracle_id,
            market_config_id,
        });

        transfer::share_object(oracle);
        oracle_id
    }

    /// Push a new implied-rate observation into the oracle buffer.
    ///
    /// Enforces:
    /// - The new timestamp must be strictly greater than the last recorded one
    ///   (`EStaleUpdate`).
    /// - At least `min_update_interval_ms` must have elapsed since the last push
    ///   (`ETooFrequent`).
    ///
    /// When the buffer is full the oldest observation is removed before appending
    /// (rotating circular buffer).
    public fun push_observation(
        oracle: &mut RateOracleConfig,
        implied_rate_wad: u128,
        clock: &Clock,
    ) {
        let now_ms = clock.timestamp_ms();

        assert!(now_ms > oracle.last_update_ms, EStaleUpdate);
        assert!(
            now_ms - oracle.last_update_ms >= oracle.min_update_interval_ms,
            ETooFrequent,
        );

        let time_elapsed_ms = now_ms - oracle.last_update_ms;

        // Derive the cumulative value by extending the previous cumulative.
        let prev_cumulative = if (vector::is_empty(&oracle.observations)) {
            0u128
        } else {
            let last_idx = vector::length(&oracle.observations) - 1;
            vector::borrow(&oracle.observations, last_idx).cumulative_rate
        };

        let cumulative_rate = amm_math::calc_cumulative_rate(
            prev_cumulative,
            implied_rate_wad,
            time_elapsed_ms,
        );

        // Rotate the buffer when it has reached capacity.
        if (vector::length(&oracle.observations) >= oracle.max_observations) {
            vector::remove(&mut oracle.observations, 0);
        };

        vector::push_back(&mut oracle.observations, Observation {
            timestamp_ms: now_ms,
            implied_rate_wad,
            cumulative_rate,
        });

        oracle.last_update_ms = now_ms;

        event::emit(OracleUpdated {
            oracle_id: object::id(oracle),
            implied_rate_wad,
            timestamp_ms: now_ms,
        });
    }

    /// Compute the TWAP implied annual rate over the requested `duration_ms`
    /// ending at the current wall-clock time.
    ///
    /// Algorithm:
    /// 1. Require at least 2 observations (`EInsufficientHistory`).
    /// 2. Require `duration_ms > 0` (`EInvalidDuration`).
    /// 3. Walk backward through the buffer to find the observation whose
    ///    timestamp is closest to `(now - duration_ms)`.
    /// 4. Delegate to `amm_math::calc_twap_rate` with the cumulative values
    ///    from that observation to the most recent one.
    public fun get_twap(
        oracle: &RateOracleConfig,
        duration_ms: u64,
        clock: &Clock,
    ): u128 {
        let count = vector::length(&oracle.observations);
        assert!(count >= 2, EInsufficientHistory);
        assert!(duration_ms > 0, EInvalidDuration);

        let now_ms = clock.timestamp_ms();
        // Target timestamp: the point in history we want as the start of the window.
        // Saturate to 0 to avoid underflow when duration_ms > now_ms.
        let target_ms = if (now_ms >= duration_ms) { now_ms - duration_ms } else { 0 };

        // Find the observation closest to target_ms.  We scan forward; the first
        // observation whose timestamp exceeds target_ms is our boundary candidate,
        // but we also consider the one just before it for closeness.
        let newest = vector::borrow(&oracle.observations, count - 1);

        // If all observations are newer than target, use the oldest available.
        let oldest = vector::borrow(&oracle.observations, 0);
        if (oldest.timestamp_ms >= target_ms) {
            // Use full available history.
            let actual_elapsed = newest.timestamp_ms - oldest.timestamp_ms;
            return amm_math::calc_twap_rate(
                oldest.cumulative_rate,
                newest.cumulative_rate,
                actual_elapsed,
            )
        };

        // Binary-search for the last observation with timestamp <= target_ms.
        let mut lo: u64 = 0;
        let mut hi: u64 = count - 1;

        while (lo + 1 < hi) {
            let mid = (lo + hi) / 2;
            let mid_ts = vector::borrow(&oracle.observations, mid).timestamp_ms;
            if (mid_ts <= target_ms) {
                lo = mid;
            } else {
                hi = mid;
            };
        };

        // `lo` is the last index with timestamp <= target_ms.
        // Pick whichever of `lo` and `hi` is closer to target_ms.
        let lo_obs = vector::borrow(&oracle.observations, lo);
        let hi_obs = vector::borrow(&oracle.observations, hi);

        let start_obs = if (
            target_ms - lo_obs.timestamp_ms <= hi_obs.timestamp_ms - target_ms
        ) {
            lo_obs
        } else {
            hi_obs
        };

        let actual_elapsed = newest.timestamp_ms - start_obs.timestamp_ms;
        amm_math::calc_twap_rate(
            start_obs.cumulative_rate,
            newest.cumulative_rate,
            actual_elapsed,
        )
    }

    /// Return the most recently pushed implied annual rate (WAD-scaled).
    /// Returns 0 when no observations have been recorded yet.
    public fun get_latest_rate(oracle: &RateOracleConfig): u128 {
        let count = vector::length(&oracle.observations);
        if (count == 0) return 0;
        vector::borrow(&oracle.observations, count - 1).implied_rate_wad
    }

    /// Return the number of observations currently stored in the buffer.
    public fun observation_count(oracle: &RateOracleConfig): u64 {
        vector::length(&oracle.observations)
    }

    /// Return the timestamp of the most recent observation (ms).
    public fun last_update_ms(oracle: &RateOracleConfig): u64 {
        oracle.last_update_ms
    }

    // ===== Tests =====

    #[test_only]
    use sui::clock;
    #[test_only]
    use sui::test_scenario;

    #[test]
    fun test_create_and_push() {
        let mut scenario = test_scenario::begin(@0xA);
        {
            let ctx = test_scenario::ctx(&mut scenario);
            let mut clk = clock::create_for_testing(ctx);
            clock::set_for_testing(&mut clk, 100_000);

            let market_id = object::id_from_address(@0xB);
            let _oracle_id = create_oracle(market_id, &clk, ctx);

            clock::destroy_for_testing(clk);
        };
        test_scenario::end(scenario);
    }

    #[test]
    fun test_push_and_query() {
        let mut scenario = test_scenario::begin(@0xA);
        {
            let ctx = test_scenario::ctx(&mut scenario);
            let mut clk = clock::create_for_testing(ctx);
            // t = 0
            clock::set_for_testing(&mut clk, 0);

            let market_id = object::id_from_address(@0xB);
            let oracle_id = create_oracle(market_id, &clk, ctx);
            let _ = oracle_id;

            clock::destroy_for_testing(clk);
        };

        test_scenario::next_tx(&mut scenario, @0xA);
        {
            let mut oracle = test_scenario::take_shared<RateOracleConfig>(&scenario);
            let ctx = test_scenario::ctx(&mut scenario);
            let mut clk = clock::create_for_testing(ctx);

            let rate_7pct: u128 = 70_000_000_000_000_000; // 7 % in WAD

            // First push at t = 30 s.
            clock::set_for_testing(&mut clk, 30_000);
            push_observation(&mut oracle, rate_7pct, &clk);
            assert!(observation_count(&oracle) == 1);
            assert!(get_latest_rate(&oracle) == rate_7pct);

            // Second push at t = 60 s.
            clock::set_for_testing(&mut clk, 60_000);
            push_observation(&mut oracle, rate_7pct, &clk);
            assert!(observation_count(&oracle) == 2);

            // TWAP over a 30-second window should be approximately 7 %.
            let twap = get_twap(&oracle, 30_000, &clk);
            // Allow generous tolerance: must be within ±1 % of 7 %.
            let tolerance: u128 = 10_000_000_000_000_000; // 1 % in WAD
            let diff = if (twap > rate_7pct) { twap - rate_7pct } else { rate_7pct - twap };
            assert!(diff < tolerance);

            clock::destroy_for_testing(clk);
            test_scenario::return_shared(oracle);
        };
        test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = ETooFrequent)]
    fun test_too_frequent_rejected() {
        let mut scenario = test_scenario::begin(@0xA);
        {
            let ctx = test_scenario::ctx(&mut scenario);
            let mut clk = clock::create_for_testing(ctx);
            clock::set_for_testing(&mut clk, 0);
            let market_id = object::id_from_address(@0xC);
            create_oracle(market_id, &clk, ctx);
            clock::destroy_for_testing(clk);
        };

        test_scenario::next_tx(&mut scenario, @0xA);
        {
            let mut oracle = test_scenario::take_shared<RateOracleConfig>(&scenario);
            let ctx = test_scenario::ctx(&mut scenario);
            let mut clk = clock::create_for_testing(ctx);

            let rate: u128 = WAD / 10; // 10 %

            clock::set_for_testing(&mut clk, 30_000);
            push_observation(&mut oracle, rate, &clk);

            // Only 1 ms later — should abort with ETooFrequent.
            clock::set_for_testing(&mut clk, 30_001);
            push_observation(&mut oracle, rate, &clk);

            clock::destroy_for_testing(clk);
            test_scenario::return_shared(oracle);
        };
        test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = EInsufficientHistory)]
    fun test_twap_requires_two_observations() {
        let mut scenario = test_scenario::begin(@0xA);
        {
            let ctx = test_scenario::ctx(&mut scenario);
            let mut clk = clock::create_for_testing(ctx);
            clock::set_for_testing(&mut clk, 0);
            let market_id = object::id_from_address(@0xD);
            create_oracle(market_id, &clk, ctx);
            clock::destroy_for_testing(clk);
        };

        test_scenario::next_tx(&mut scenario, @0xA);
        {
            let mut oracle = test_scenario::take_shared<RateOracleConfig>(&scenario);
            let ctx = test_scenario::ctx(&mut scenario);
            let mut clk = clock::create_for_testing(ctx);

            clock::set_for_testing(&mut clk, 30_000);
            push_observation(&mut oracle, WAD / 10, &clk);

            // Only one observation — get_twap must abort.
            let _twap = get_twap(&oracle, 30_000, &clk);

            clock::destroy_for_testing(clk);
            test_scenario::return_shared(oracle);
        };
        test_scenario::end(scenario);
    }
}
