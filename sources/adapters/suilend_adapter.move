/// Suilend Adapter — integration layer for Suilend lending protocol (cTokens).
/// Wraps Suilend lending deposit/withdrawal operations and provides exchange rate
/// tracking for the Crux SY vault.
///
/// Suilend Protocol:
///   - Users deposit underlying assets (SUI, USDC, etc.) → receive cTokens (cSUI, cUSDC)
///   - cTokens accrue lending yield (~3-8% variable APY)
///   - cToken/underlying exchange rate increases as interest accrues
///
/// This adapter enables:
///   - cToken → SY wrapping for yield tokenization
///   - Exchange rate synchronization from Suilend to Crux SY vault
///   - Future: direct underlying → cToken → SY → PT pipeline
module crux::suilend_adapter {

    use sui::clock::Clock;
    use sui::event;

    use crux::standardized_yield::{Self, SYVault};

    // ===== Constants =====

    const WAD: u128 = 1_000_000_000_000_000_000;

    // ===== Error Codes =====

    const EStaleRate: u64 = 710;
    const ERateDecreased: u64 = 711;

    // ===== Structs =====

    /// Configuration for the Suilend adapter.
    /// Stores the reference to a Suilend lending market for rate queries.
    public struct SuilendAdapterConfig has key {
        id: UID,
        /// The SY vault ID this adapter feeds
        sy_vault_id: ID,
        /// Index of the Suilend lending market this adapter connects to
        market_index: u64,
        /// Last known cToken/underlying exchange rate (WAD-scaled)
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
        market_index: u64,
        old_rate: u128,
        new_rate: u128,
        timestamp_ms: u64,
    }

    // ===== Functions =====

    /// Create the Suilend adapter configuration.
    /// Links to a specific SY vault and Suilend lending market.
    public fun create_adapter(
        sy_vault_id: ID,
        market_index: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): ID {
        let config = SuilendAdapterConfig {
            id: object::new(ctx),
            sy_vault_id,
            market_index,
            last_known_rate: WAD, // 1:1 initially
            last_sync_ms: clock.timestamp_ms(),
            min_sync_interval_ms: 30_000, // 30 seconds minimum between syncs
        };
        let id = object::id(&config);
        sui::transfer::share_object(config);
        id
    }

    /// Sync the cToken exchange rate from Suilend to the Crux SY vault.
    /// Called by the keeper bot periodically.
    ///
    /// In production, this would read the rate directly from Suilend's reserve state
    /// shared object. For the prototype, the rate is passed as a parameter
    /// (to be replaced with direct Suilend state read in mainnet integration).
    ///
    /// The keeper bot reads Suilend's reserve `cToken/underlying` ratio off-chain
    /// and passes it here for on-chain verification and propagation.
    public fun sync_rate<T>(
        adapter: &mut SuilendAdapterConfig,
        vault: &mut SYVault<T>,
        new_ctoken_rate: u128,
        clock: &Clock,
    ) {
        let now = clock.timestamp_ms();

        // Enforce minimum sync interval
        assert!(
            now >= adapter.last_sync_ms + adapter.min_sync_interval_ms,
            EStaleRate,
        );

        // Rate must be non-decreasing (cTokens only accrue value)
        assert!(new_ctoken_rate >= adapter.last_known_rate, ERateDecreased);

        let old_rate = adapter.last_known_rate;
        adapter.last_known_rate = new_ctoken_rate;
        adapter.last_sync_ms = now;

        // Propagate rate update to the SY vault
        standardized_yield::update_exchange_rate(vault, new_ctoken_rate, clock);

        event::emit(RateSynced {
            adapter_id: object::id(adapter),
            sy_vault_id: adapter.sy_vault_id,
            market_index: adapter.market_index,
            old_rate,
            new_rate: new_ctoken_rate,
            timestamp_ms: now,
        });
    }

    /// Get the last known cToken/underlying exchange rate
    public fun last_known_rate(adapter: &SuilendAdapterConfig): u128 {
        adapter.last_known_rate
    }

    /// Get the SY vault ID this adapter services
    public fun sy_vault_id(adapter: &SuilendAdapterConfig): ID {
        adapter.sy_vault_id
    }

    /// Get the Suilend lending market index
    public fun market_index(adapter: &SuilendAdapterConfig): u64 {
        adapter.market_index
    }

    /// Get the last sync timestamp
    public fun last_sync_ms(adapter: &SuilendAdapterConfig): u64 {
        adapter.last_sync_ms
    }
}
