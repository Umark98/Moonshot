/// Scallop Adapter — integration layer for Scallop Protocol lending deposits.
/// Wraps Scallop lending deposit/withdraw operations and provides exchange rate
/// tracking for the Crux SY vault.
///
/// Scallop Protocol:
///   - Users deposit tokens → receive sCoins (sSUI, sUSDC, etc.) as deposit receipts
///   - sCoins accrue lending yield (~3-8% variable APY)
///   - sCoin / underlying exchange rate increases monotonically
///
/// This adapter enables:
///   - Scallop sCoins → SY wrapping for yield tokenization
///   - Exchange rate synchronization from Scallop to Crux SY vault
///   - Future: direct underlying → sCoin → SY → PT pipeline
module crux::scallop_adapter {

    use sui::clock::Clock;
    use sui::event;

    use crux::standardized_yield::{Self, SYVault};

    // ===== Constants =====

    const WAD: u128 = 1_000_000_000_000_000_000;

    // ===== Error Codes =====

    const EStaleRate: u64 = 730;
    const ERateDecreased: u64 = 731;

    // ===== Structs =====

    /// Configuration for the Scallop adapter.
    /// Stores the reference to Scallop's lending market for rate queries.
    public struct ScallopAdapterConfig has key {
        id: UID,
        /// The SY vault ID this adapter feeds
        sy_vault_id: ID,
        /// Reference to which Scallop lending market this adapter connects to
        market_id: ID,
        /// Last known sCoin / underlying exchange rate (WAD-scaled)
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
        market_id: ID,
        old_rate: u128,
        new_rate: u128,
        timestamp_ms: u64,
    }

    // ===== Functions =====

    /// Create the Scallop adapter configuration.
    /// Links to a specific SY vault and Scallop lending market.
    public fun create_adapter(
        sy_vault_id: ID,
        market_id: ID,
        clock: &Clock,
        ctx: &mut TxContext,
    ): ID {
        let config = ScallopAdapterConfig {
            id: object::new(ctx),
            sy_vault_id,
            market_id,
            last_known_rate: WAD, // 1:1 initially
            last_sync_ms: clock.timestamp_ms(),
            min_sync_interval_ms: 30_000, // 30 seconds minimum between syncs
        };
        let id = object::id(&config);
        sui::transfer::share_object(config);
        id
    }

    /// Sync the Scallop sCoin exchange rate to the Crux SY vault.
    /// Called by the keeper bot periodically.
    ///
    /// In production, this would read the rate directly from Scallop's lending market
    /// shared object. For the prototype, the rate is passed as a parameter
    /// (to be replaced with direct Scallop state read in mainnet integration).
    ///
    /// The keeper bot reads Scallop's lending market exchange rate off-chain
    /// and passes it here for on-chain verification and propagation.
    public fun sync_rate<T>(
        adapter: &mut ScallopAdapterConfig,
        vault: &mut SYVault<T>,
        new_scallop_rate: u128,
        clock: &Clock,
    ) {
        let now = clock.timestamp_ms();

        // Enforce minimum sync interval
        assert!(
            now >= adapter.last_sync_ms + adapter.min_sync_interval_ms,
            EStaleRate,
        );

        // Rate must be non-decreasing (Scallop sCoins only accrue value)
        assert!(new_scallop_rate >= adapter.last_known_rate, ERateDecreased);

        let old_rate = adapter.last_known_rate;
        adapter.last_known_rate = new_scallop_rate;
        adapter.last_sync_ms = now;

        // Propagate rate update to the SY vault
        standardized_yield::update_exchange_rate_internal(vault, new_scallop_rate, clock);

        event::emit(RateSynced {
            adapter_id: object::id(adapter),
            sy_vault_id: adapter.sy_vault_id,
            market_id: adapter.market_id,
            old_rate,
            new_rate: new_scallop_rate,
            timestamp_ms: now,
        });
    }

    /// Get the last known sCoin / underlying exchange rate
    public fun last_known_rate(adapter: &ScallopAdapterConfig): u128 {
        adapter.last_known_rate
    }

    /// Get the SY vault ID this adapter services
    public fun sy_vault_id(adapter: &ScallopAdapterConfig): ID {
        adapter.sy_vault_id
    }

    /// Get the Scallop lending market ID this adapter connects to
    public fun market_id(adapter: &ScallopAdapterConfig): ID {
        adapter.market_id
    }

    /// Get the last sync timestamp
    public fun last_sync_ms(adapter: &ScallopAdapterConfig): u64 {
        adapter.last_sync_ms
    }
}
