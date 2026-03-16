/// Pyth Adapter — integration layer for Pyth Network price feeds.
/// Provides USD price data for underlying assets, used when PT is collateral
/// in lending protocols to determine the USD value of the position.
///
/// Pyth Network:
///   - Publishes high-frequency, low-latency price feeds for crypto assets
///   - Each feed is identified by a 32-byte price feed ID
///   - Prices include a confidence interval (uncertainty band)
///
/// This adapter enables:
///   - On-chain USD price queries for any Pyth-supported asset
///   - Staleness enforcement to reject outdated price data
///   - Confidence filtering to reject low-quality price observations
module crux::pyth_adapter {

    use sui::clock::Clock;
    use sui::event;

    // ===== Constants =====

    const WAD: u128 = 1_000_000_000_000_000_000;

    /// Maximum acceptable confidence/price ratio: 5% (WAD-scaled).
    /// Rejects feeds where uncertainty is too high relative to the price.
    const MAX_CONFIDENCE_RATIO_WAD: u128 = 50_000_000_000_000_000;

    // ===== Error Codes =====

    /// Price data is older than `max_staleness_ms`.
    const EStalePrice: u64 = 740;
    /// Price feed returned a non-positive price.
    const EPriceNegative: u64 = 741;
    /// Confidence interval exceeds the allowed ratio of the price.
    const EConfidenceTooWide: u64 = 742;

    // ===== Structs =====

    /// Configuration and live state for a single Pyth price feed.
    /// Stored as a shared object so the keeper bot can update it and
    /// lending protocols can read it in the same transaction.
    public struct PythAdapterConfig has key {
        id: UID,
        /// Pyth price feed ID (32 bytes), uniquely identifies the asset feed.
        price_feed_id: vector<u8>,
        /// Human-readable asset name, e.g. b"SUI/USD".
        asset_name: vector<u8>,
        /// Last accepted price, WAD-scaled (18 decimals).
        last_price_wad: u128,
        /// Last accepted confidence interval, WAD-scaled.
        last_confidence_wad: u128,
        /// Timestamp of the last accepted price update (ms since Unix epoch).
        last_update_ms: u64,
        /// Maximum age of an acceptable price observation in milliseconds.
        max_staleness_ms: u64,
    }

    // ===== Events =====

    public struct PriceUpdated has copy, drop {
        adapter_id: ID,
        old_price: u128,
        new_price: u128,
        confidence: u128,
        timestamp_ms: u64,
    }

    // ===== Functions =====

    /// Create a new Pyth adapter configuration and share it on-chain.
    /// Returns the object ID so callers can reference the shared object.
    ///
    /// `price_feed_id`  — 32-byte Pyth feed ID for the asset.
    /// `asset_name`     — human-readable label, e.g. b"BTC/USD".
    /// `max_staleness_ms` — reject prices older than this many milliseconds.
    public fun create_adapter(
        price_feed_id: vector<u8>,
        asset_name: vector<u8>,
        max_staleness_ms: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): ID {
        let config = PythAdapterConfig {
            id: object::new(ctx),
            price_feed_id,
            asset_name,
            last_price_wad: 0,
            last_confidence_wad: 0,
            last_update_ms: clock.timestamp_ms(),
            max_staleness_ms,
        };
        let id = object::id(&config);
        sui::transfer::share_object(config);
        id
    }

    /// Push a new price observation into the adapter.
    /// Called by the keeper bot after reading from the Pyth contract off-chain.
    ///
    /// Enforces three invariants before accepting the update:
    ///   1. `new_price_wad` must be strictly positive.
    ///   2. The confidence/price ratio must not exceed `MAX_CONFIDENCE_RATIO_WAD`.
    ///   3. The current clock time must not already make the update stale
    ///      (i.e. the keeper is submitting a timely observation).
    public fun update_price(
        adapter: &mut PythAdapterConfig,
        new_price_wad: u128,
        new_confidence_wad: u128,
        clock: &Clock,
    ) {
        let now = clock.timestamp_ms();

        // Price must be positive — a zero or wrapped-negative feed is unusable.
        assert!(new_price_wad > 0, EPriceNegative);

        // Confidence/price ratio must be <= MAX_CONFIDENCE_RATIO_WAD (5%).
        // Computed as: (confidence * WAD) / price <= MAX_CONFIDENCE_RATIO_WAD.
        let confidence_ratio = (new_confidence_wad * WAD) / new_price_wad;
        assert!(confidence_ratio <= MAX_CONFIDENCE_RATIO_WAD, EConfidenceTooWide);

        // The observation being pushed must not itself be stale.
        assert!(
            now <= adapter.last_update_ms + adapter.max_staleness_ms || adapter.last_price_wad == 0,
            EStalePrice,
        );

        let old_price = adapter.last_price_wad;
        adapter.last_price_wad = new_price_wad;
        adapter.last_confidence_wad = new_confidence_wad;
        adapter.last_update_ms = now;

        event::emit(PriceUpdated {
            adapter_id: object::id(adapter),
            old_price,
            new_price: new_price_wad,
            confidence: new_confidence_wad,
            timestamp_ms: now,
        });
    }

    /// Read the current price and confidence interval.
    /// Aborts with `EStalePrice` if the last update is older than `max_staleness_ms`.
    /// Returns `(price_wad, confidence_wad)`.
    public fun get_price(adapter: &PythAdapterConfig, clock: &Clock): (u128, u128) {
        assert!(!is_stale(adapter, clock), EStalePrice);
        (adapter.last_price_wad, adapter.last_confidence_wad)
    }

    /// Returns the last stored price in WAD without a staleness check.
    public fun last_price(adapter: &PythAdapterConfig): u128 {
        adapter.last_price_wad
    }

    /// Returns the last stored confidence interval in WAD without a staleness check.
    public fun last_confidence(adapter: &PythAdapterConfig): u128 {
        adapter.last_confidence_wad
    }

    /// Returns the timestamp (ms) of the last accepted price update.
    public fun last_update_ms(adapter: &PythAdapterConfig): u64 {
        adapter.last_update_ms
    }

    /// Returns the human-readable asset name stored in the adapter.
    public fun asset_name(adapter: &PythAdapterConfig): vector<u8> {
        adapter.asset_name
    }

    /// Returns `true` if the last price update is older than `max_staleness_ms`.
    public fun is_stale(adapter: &PythAdapterConfig, clock: &Clock): bool {
        let now = clock.timestamp_ms();
        now > adapter.last_update_ms + adapter.max_staleness_ms
    }
}
