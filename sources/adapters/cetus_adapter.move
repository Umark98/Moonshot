/// Cetus Adapter — integration layer for Cetus Protocol CLMM LP positions.
/// Wraps Cetus concentrated liquidity LP position operations and provides
/// LP value rate tracking for the Crux SY vault.
///
/// Cetus Protocol:
///   - Users provide liquidity to CLMM pools → receive LP positions as NFT receipts
///   - LP positions earn trading fees distributed in both pool tokens
///   - LP positions additionally accrue CETUS token rewards (~10-30% variable APY)
///   - LP value per unit fluctuates with fee accrual, reward emissions, and price range activity
///
/// This adapter enables:
///   - Cetus CLMM LP positions → SY wrapping for yield tokenization
///   - LP value rate synchronization from Cetus to Crux SY vault
///   - Future: direct token pair → LP position → SY → PT pipeline
module crux::cetus_adapter {

    use sui::clock::Clock;
    use sui::event;

    use crux::standardized_yield::{Self, SYVault};

    // ===== Constants =====

    const WAD: u128 = 1_000_000_000_000_000_000;

    // ===== Error Codes =====

    const EStaleRate: u64 = 760;
    const ERateDecreased: u64 = 761;

    // ===== Structs =====

    /// Configuration for the Cetus adapter.
    /// Stores the reference to a specific Cetus CLMM pool for LP rate queries.
    public struct CetusAdapterConfig has key {
        id: UID,
        /// The SY vault ID this adapter feeds
        sy_vault_id: ID,
        /// Reference to the Cetus CLMM pool this adapter connects to
        pool_id: ID,
        /// Last known LP value per unit (WAD-scaled)
        /// Reflects accrued trading fees and CETUS reward emissions
        last_known_rate: u128,
        /// Last sync timestamp
        last_sync_ms: u64,
        /// Minimum sync interval (ms) to prevent excessive updates.
        /// Longer than lending adapters (60s) since CLMM LP value changes
        /// less frequently than money-market exchange rates.
        min_sync_interval_ms: u64,
    }

    // ===== Events =====

    public struct RateSynced has copy, drop {
        adapter_id: ID,
        sy_vault_id: ID,
        pool_id: ID,
        old_rate: u128,
        new_rate: u128,
        timestamp_ms: u64,
    }

    // ===== Functions =====

    /// Create the Cetus adapter configuration.
    /// Links to a specific SY vault and Cetus CLMM pool.
    public fun create_adapter(
        sy_vault_id: ID,
        pool_id: ID,
        clock: &Clock,
        ctx: &mut TxContext,
    ): ID {
        let config = CetusAdapterConfig {
            id: object::new(ctx),
            sy_vault_id,
            pool_id,
            last_known_rate: WAD, // 1:1 initially
            last_sync_ms: clock.timestamp_ms(),
            min_sync_interval_ms: 60_000, // 60 seconds minimum between syncs
        };
        let id = object::id(&config);
        sui::transfer::share_object(config);
        id
    }

    /// Sync the Cetus CLMM LP value rate to the Crux SY vault.
    /// Called by the keeper bot periodically.
    ///
    /// In production, this would read the LP value rate directly from Cetus's
    /// CLMM pool shared object, aggregating accrued trading fees and CETUS
    /// reward emissions into a single WAD-scaled rate. For the prototype, the
    /// rate is passed as a parameter (to be replaced with direct Cetus pool
    /// state read in mainnet integration).
    ///
    /// The keeper bot reads Cetus CLMM pool state off-chain — computing LP value
    /// per unit from fee growth globals and reward accumulators — and passes it
    /// here for on-chain verification and propagation.
    public fun sync_rate<T>(
        adapter: &mut CetusAdapterConfig,
        vault: &mut SYVault<T>,
        new_lp_rate: u128,
        clock: &Clock,
    ) {
        let now = clock.timestamp_ms();

        // Enforce minimum sync interval
        assert!(
            now >= adapter.last_sync_ms + adapter.min_sync_interval_ms,
            EStaleRate,
        );

        // Rate must be non-decreasing (LP positions only accumulate fees and rewards)
        assert!(new_lp_rate >= adapter.last_known_rate, ERateDecreased);

        let old_rate = adapter.last_known_rate;
        adapter.last_known_rate = new_lp_rate;
        adapter.last_sync_ms = now;

        // Propagate rate update to the SY vault
        standardized_yield::update_exchange_rate(vault, new_lp_rate, clock);

        event::emit(RateSynced {
            adapter_id: object::id(adapter),
            sy_vault_id: adapter.sy_vault_id,
            pool_id: adapter.pool_id,
            old_rate,
            new_rate: new_lp_rate,
            timestamp_ms: now,
        });
    }

    /// Get the last known LP value per unit (WAD-scaled).
    /// Reflects cumulative trading fees and CETUS rewards earned by the position.
    public fun last_known_rate(adapter: &CetusAdapterConfig): u128 {
        adapter.last_known_rate
    }

    /// Get the SY vault ID this adapter services
    public fun sy_vault_id(adapter: &CetusAdapterConfig): ID {
        adapter.sy_vault_id
    }

    /// Get the Cetus CLMM pool ID this adapter connects to
    public fun pool_id(adapter: &CetusAdapterConfig): ID {
        adapter.pool_id
    }

    /// Get the last sync timestamp
    public fun last_sync_ms(adapter: &CetusAdapterConfig): u64 {
        adapter.last_sync_ms
    }
}
