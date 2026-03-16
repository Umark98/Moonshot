/// Haedal Adapter — integration layer for Haedal liquid staking (haSUI).
/// Wraps haSUI staking/unstaking operations and provides exchange rate tracking
/// for the Crux SY vault.
///
/// Haedal Protocol:
///   - Users stake SUI → receive haSUI (liquid staking derivative)
///   - haSUI accrues staking yield (~6-8% APY)
///   - haSUI/SUI exchange rate increases monotonically
///
/// This adapter enables:
///   - haSUI → SY wrapping for yield tokenization
///   - Exchange rate synchronization from Haedal to Crux SY vault
///   - Future: direct SUI → haSUI → SY → PT pipeline
module crux::haedal_adapter {

    use sui::clock::Clock;
    use sui::event;

    use crux::standardized_yield::{Self, SYVault};

    // ===== Constants =====

    const WAD: u128 = 1_000_000_000_000_000_000;

    // ===== Error Codes =====

    const EStaleRate: u64 = 700;
    const ERateDecreased: u64 = 701;

    // ===== Structs =====

    /// Configuration for the Haedal adapter.
    /// Stores the reference to Haedal's staking pool for rate queries.
    public struct HaedalAdapterConfig has key {
        id: UID,
        /// The SY vault ID this adapter feeds
        sy_vault_id: ID,
        /// Last known haSUI/SUI exchange rate (WAD-scaled)
        last_known_rate: u128,
        /// Last sync timestamp
        last_sync_ms: u64,
        /// Minimum sync interval (ms) to prevent excessive updates
        min_sync_interval_ms: u64,
    }

    // ===== Events =====

    public struct RateSynced has copy, drop {
        adapter_id: ID,
        sy_vault_id: ID,
        old_rate: u128,
        new_rate: u128,
        timestamp_ms: u64,
    }

    // ===== Functions =====

    /// Create the Haedal adapter configuration.
    /// Links to a specific SY vault for haSUI.
    public fun create_adapter(
        sy_vault_id: ID,
        clock: &Clock,
        ctx: &mut TxContext,
    ): ID {
        let config = HaedalAdapterConfig {
            id: object::new(ctx),
            sy_vault_id,
            last_known_rate: WAD, // 1:1 initially
            last_sync_ms: clock.timestamp_ms(),
            min_sync_interval_ms: 30_000, // 30 seconds minimum between syncs
        };
        let id = object::id(&config);
        sui::transfer::share_object(config);
        id
    }

    /// Sync the haSUI exchange rate from Haedal to the Crux SY vault.
    /// Called by the keeper bot periodically.
    ///
    /// In production, this would read the rate directly from Haedal's staking pool
    /// shared object. For the prototype, the rate is passed as a parameter
    /// (to be replaced with direct Haedal state read in mainnet integration).
    ///
    /// The keeper bot reads Haedal's `StakingPool.exchange_rate` off-chain
    /// and passes it here for on-chain verification and propagation.
    public fun sync_rate<T>(
        adapter: &mut HaedalAdapterConfig,
        vault: &mut SYVault<T>,
        new_hasui_rate: u128,
        clock: &Clock,
    ) {
        let now = clock.timestamp_ms();

        // Enforce minimum sync interval
        assert!(
            now >= adapter.last_sync_ms + adapter.min_sync_interval_ms,
            EStaleRate,
        );

        // Rate must be non-decreasing (haSUI only accrues value)
        assert!(new_hasui_rate >= adapter.last_known_rate, ERateDecreased);

        let old_rate = adapter.last_known_rate;
        adapter.last_known_rate = new_hasui_rate;
        adapter.last_sync_ms = now;

        // Propagate rate update to the SY vault
        standardized_yield::update_exchange_rate_internal(vault, new_hasui_rate, clock);

        event::emit(RateSynced {
            adapter_id: object::id(adapter),
            sy_vault_id: adapter.sy_vault_id,
            old_rate,
            new_rate: new_hasui_rate,
            timestamp_ms: now,
        });
    }

    /// Get the last known haSUI/SUI exchange rate
    public fun last_known_rate(adapter: &HaedalAdapterConfig): u128 {
        adapter.last_known_rate
    }

    /// Get the SY vault ID this adapter services
    public fun sy_vault_id(adapter: &HaedalAdapterConfig): ID {
        adapter.sy_vault_id
    }

    /// Get the last sync timestamp
    public fun last_sync_ms(adapter: &HaedalAdapterConfig): u64 {
        adapter.last_sync_ms
    }
}
