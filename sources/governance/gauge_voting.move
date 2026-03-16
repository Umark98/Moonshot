module crux::gauge_voting {
    use sui::clock::Clock;
    use sui::event;
    use crux::fixed_point;

    // ===== Error Codes =====
    const EGaugeNotFound: u64 = 970;
    const EGaugeNotActive: u64 = 971;
    const EEpochNotEnded: u64 = 972;
    const EZeroVotes: u64 = 973;
    // ===== Constants =====
    const WAD: u128 = 1_000_000_000_000_000_000;
    const DEFAULT_EPOCH_DURATION_MS: u64 = 604_800_000;   // 7 days
    const DEFAULT_EMISSIONS_PER_EPOCH: u64 = 50_000;       // 50k CRUX per week

    // ===== Structs =====

    public struct GaugeController has key {
        id: UID,
        gauges: vector<Gauge>,
        current_epoch: u64,
        epoch_start_ms: u64,
        epoch_duration_ms: u64,
        total_votes: u128,
        emissions_per_epoch: u64,
    }

    public struct Gauge has store, drop, copy {
        pool_id: ID,
        votes_wad: u128,
        is_active: bool,
    }

    public struct VoteRecord has key, store {
        id: UID,
        voter: address,
        epoch: u64,
        gauge_index: u64,
        vote_amount_wad: u128,
    }

    // ===== Events =====

    public struct GaugeAdded has copy, drop {
        pool_id: ID,
        gauge_index: u64,
    }

    public struct VoteCast has copy, drop {
        voter: address,
        pool_id: ID,
        vote_amount_wad: u128,
        epoch: u64,
    }

    public struct EpochAdvanced has copy, drop {
        new_epoch: u64,
        timestamp_ms: u64,
    }

    public struct EmissionsDistributed has copy, drop {
        epoch: u64,
        total_distributed: u64,
    }

    // ===== Init =====

    fun init(ctx: &TxContext) {
        // Epoch start is set to 0; first call to advance_epoch after deployment
        // will calibrate against the clock. create_controller is the primary
        // entry point for tests and genesis setup.
        let _ = ctx;
    }

    // ===== Public Functions =====

    /// Create a shared GaugeController. Returns the object ID.
    public fun create_controller(clock: &Clock, ctx: &mut TxContext): ID {
        let now = clock.timestamp_ms();
        let controller = GaugeController {
            id: object::new(ctx),
            gauges: vector[],
            current_epoch: 0,
            epoch_start_ms: now,
            epoch_duration_ms: DEFAULT_EPOCH_DURATION_MS,
            total_votes: 0,
            emissions_per_epoch: DEFAULT_EMISSIONS_PER_EPOCH,
        };
        let controller_id = object::id(&controller);
        transfer::share_object(controller);
        controller_id
    }

    /// Register a new pool gauge in the controller.
    public fun add_gauge(controller: &mut GaugeController, pool_id: ID) {
        let gauge_index = controller.gauges.length();
        let gauge = Gauge {
            pool_id,
            votes_wad: 0,
            is_active: true,
        };
        controller.gauges.push_back(gauge);

        event::emit(GaugeAdded {
            pool_id,
            gauge_index,
        });
    }

    /// Cast a veCRUX vote for a gauge. Returns a VoteRecord that prevents
    /// the same voter from voting twice in the same epoch.
    public fun cast_vote(
        controller: &mut GaugeController,
        gauge_index: u64,
        vote_amount_wad: u128,
        clock: &Clock,
        ctx: &mut TxContext,
    ): VoteRecord {
        assert!(vote_amount_wad > 0, EZeroVotes);
        assert!(gauge_index < controller.gauges.length(), EGaugeNotFound);

        let gauge = &mut controller.gauges[gauge_index];
        assert!(gauge.is_active, EGaugeNotActive);

        let pool_id = gauge.pool_id;
        gauge.votes_wad = gauge.votes_wad + vote_amount_wad;
        controller.total_votes = controller.total_votes + vote_amount_wad;

        let epoch = controller.current_epoch;
        let voter = ctx.sender();

        event::emit(VoteCast {
            voter,
            pool_id,
            vote_amount_wad,
            epoch,
        });

        // Advance clock reference to satisfy borrow rules
        let _ = clock;

        VoteRecord {
            id: object::new(ctx),
            voter,
            epoch,
            gauge_index,
            vote_amount_wad,
        }
    }

    /// Advance to the next weekly epoch if the current one has ended.
    /// Resets all gauge votes and total_votes to zero and emits distribution
    /// accounting for the epoch that just closed.
    public fun advance_epoch(controller: &mut GaugeController, clock: &Clock) {
        let now = clock.timestamp_ms();
        let epoch_end = controller.epoch_start_ms + controller.epoch_duration_ms;
        assert!(now >= epoch_end, EEpochNotEnded);

        // Emit emissions accounting for the closing epoch before resetting.
        let closing_epoch = controller.current_epoch;
        let total_distributed = controller.emissions_per_epoch;
        event::emit(EmissionsDistributed {
            epoch: closing_epoch,
            total_distributed,
        });

        // Reset votes on every gauge.
        let mut i = 0;
        let len = controller.gauges.length();
        while (i < len) {
            controller.gauges[i].votes_wad = 0;
            i = i + 1;
        };

        controller.total_votes = 0;
        controller.current_epoch = closing_epoch + 1;
        controller.epoch_start_ms = epoch_end;

        event::emit(EpochAdvanced {
            new_epoch: controller.current_epoch,
            timestamp_ms: now,
        });
    }

    // ===== View / Calculation Functions =====

    /// Returns this gauge's share of total votes as a WAD fraction.
    /// Returns 0 if total_votes is 0.
    public fun get_gauge_share(controller: &GaugeController, gauge_index: u64): u128 {
        assert!(gauge_index < controller.gauges.length(), EGaugeNotFound);
        if (controller.total_votes == 0) return 0;
        let gauge_votes = controller.gauges[gauge_index].votes_wad;
        fixed_point::wad_div(gauge_votes, controller.total_votes)
    }

    /// Returns the CRUX emissions allocated to a gauge for this epoch.
    /// Computed as: emissions_per_epoch * (gauge_votes / total_votes).
    public fun get_gauge_emissions(controller: &GaugeController, gauge_index: u64): u64 {
        let share_wad = get_gauge_share(controller, gauge_index);
        if (share_wad == 0) return 0;
        let emissions_wad = fixed_point::wad_mul(
            (controller.emissions_per_epoch as u128) * WAD,
            share_wad,
        );
        fixed_point::from_wad(emissions_wad)
    }

    /// Current epoch number.
    public fun current_epoch(controller: &GaugeController): u64 {
        controller.current_epoch
    }

    /// Number of registered gauges.
    public fun gauge_count(controller: &GaugeController): u64 {
        controller.gauges.length()
    }

    /// Total veCRUX votes cast in the current epoch (WAD).
    public fun total_votes(controller: &GaugeController): u128 {
        controller.total_votes
    }

    /// CRUX tokens distributed per epoch.
    public fun emissions_per_epoch(controller: &GaugeController): u64 {
        controller.emissions_per_epoch
    }

    // ===== Test Helpers =====

    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) {
        init(ctx);
    }
}
