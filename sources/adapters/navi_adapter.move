/// NAVI Adapter — integration layer for NAVI Protocol lending deposits.
/// Wraps NAVI lending deposit/withdraw operations and provides exchange rate
/// tracking for the Crux SY vault.
///
/// NAVI Protocol:
///   - Users deposit tokens → receive deposit tokens (lending derivative)
///   - Deposit tokens accrue lending yield (~3-7% variable APY)
///   - Deposit token / underlying exchange rate increases monotonically
///
/// This adapter enables:
///   - NAVI deposit tokens → SY wrapping for yield tokenization
///   - Exchange rate synchronization from NAVI to Crux SY vault
///   - Future: direct underlying → NAVI deposit → SY → PT pipeline
module crux::navi_adapter {

    use sui::clock::Clock;
    use sui::event;

    use crux::standardized_yield::{Self, SYVault};

    // ===== Constants =====

    const WAD: u128 = 1_000_000_000_000_000_000;

    // ===== Error Codes =====

    const EStaleRate: u64 = 720;
    const ERateDecreased: u64 = 721;

    // ===== Structs =====

    /// Configuration for the NAVI adapter.
    /// Stores the reference to NAVI's lending pool for rate queries.
    public struct NaviAdapterConfig has key {
        id: UID,
        /// The SY vault ID this adapter feeds
        sy_vault_id: ID,
        /// Reference to which NAVI lending pool this adapter connects to
        pool_id_ref: ID,
        /// Last known deposit token / underlying exchange rate (WAD-scaled)
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
        pool_id_ref: ID,
        old_rate: u128,
        new_rate: u128,
        timestamp_ms: u64,
    }

    // ===== Functions =====

    /// Create the NAVI adapter configuration.
    /// Links to a specific SY vault and NAVI lending pool.
    public fun create_adapter(
        sy_vault_id: ID,
        pool_id_ref: ID,
        clock: &Clock,
        ctx: &mut TxContext,
    ): ID {
        let config = NaviAdapterConfig {
            id: object::new(ctx),
            sy_vault_id,
            pool_id_ref,
            last_known_rate: WAD, // 1:1 initially
            last_sync_ms: clock.timestamp_ms(),
            min_sync_interval_ms: 30_000, // 30 seconds minimum between syncs
        };
        let id = object::id(&config);
        sui::transfer::share_object(config);
        id
    }

    /// Sync the NAVI deposit token exchange rate to the Crux SY vault.
    /// Called by the keeper bot periodically.
    ///
    /// In production, this would read the rate directly from NAVI's lending pool
    /// shared object. For the prototype, the rate is passed as a parameter
    /// (to be replaced with direct NAVI state read in mainnet integration).
    ///
    /// The keeper bot reads NAVI's lending pool exchange rate off-chain
    /// and passes it here for on-chain verification and propagation.
    public fun sync_rate<T>(
        adapter: &mut NaviAdapterConfig,
        vault: &mut SYVault<T>,
        new_navi_rate: u128,
        clock: &Clock,
    ) {
        let now = clock.timestamp_ms();

        // Enforce minimum sync interval
        assert!(
            now >= adapter.last_sync_ms + adapter.min_sync_interval_ms,
            EStaleRate,
        );

        // Rate must be non-decreasing (NAVI deposit tokens only accrue value)
        assert!(new_navi_rate >= adapter.last_known_rate, ERateDecreased);

        let old_rate = adapter.last_known_rate;
        adapter.last_known_rate = new_navi_rate;
        adapter.last_sync_ms = now;

        // Propagate rate update to the SY vault
        standardized_yield::update_exchange_rate(vault, new_navi_rate, clock);

        event::emit(RateSynced {
            adapter_id: object::id(adapter),
            sy_vault_id: adapter.sy_vault_id,
            pool_id_ref: adapter.pool_id_ref,
            old_rate,
            new_rate: new_navi_rate,
            timestamp_ms: now,
        });
    }

    /// Get the last known deposit token / underlying exchange rate
    public fun last_known_rate(adapter: &NaviAdapterConfig): u128 {
        adapter.last_known_rate
    }

    /// Get the SY vault ID this adapter services
    public fun sy_vault_id(adapter: &NaviAdapterConfig): ID {
        adapter.sy_vault_id
    }

    /// Get the NAVI lending pool ID this adapter connects to
    public fun pool_id_ref(adapter: &NaviAdapterConfig): ID {
        adapter.pool_id_ref
    }

    /// Get the last sync timestamp
    public fun last_sync_ms(adapter: &NaviAdapterConfig): u64 {
        adapter.last_sync_ms
    }
}
