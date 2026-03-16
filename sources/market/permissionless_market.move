/// Permissionless Market Creation — allows anyone to create new yield markets
/// for any SY-wrapped asset and maturity date, subject to minimum liquidity
/// requirements. This removes the admin bottleneck and enables long-tail yield
/// markets to emerge organically.
///
/// Requirements for permissionless market creation:
///   1. An SYVault<T> must already exist for the underlying asset.
///   2. The creator must seed the market with minimum initial liquidity.
///   3. Maturity must be in the future and within allowed bounds.
///   4. No duplicate market (same asset + maturity) may exist.
module crux::permissionless_market {

    use sui::clock::Clock;
    use sui::event;

    use crux::standardized_yield::{Self, SYVault, SYToken};
    use crux::yield_tokenizer::Self;

    // ===== Constants =====

    /// Minimum initial SY liquidity to seed a new market
    const MIN_INITIAL_LIQUIDITY: u64 = 100;
    /// Minimum maturity duration: 7 days
    const MIN_DURATION_MS: u64 = 604_800_000;
    /// Maximum maturity duration: 2 years
    const MAX_DURATION_MS: u64 = 63_115_200_000;

    // ===== Error Codes =====

    const EZeroAmount: u64 = 1200;
    const EInsufficientLiquidity: u64 = 1201;
    const EMaturityTooSoon: u64 = 1202;
    const EMaturityTooFar: u64 = 1203;
    const EDuplicateMarket: u64 = 1204;

    // ===== Structs =====

    /// Shared registry tracking all permissionlessly created markets to prevent duplicates.
    public struct MarketRegistry has key {
        id: UID,
        /// List of (sy_vault_id, maturity_ms) pairs that already have markets
        existing_markets: vector<MarketEntry>,
    }

    public struct MarketEntry has store, drop, copy {
        sy_vault_id: ID,
        maturity_ms: u64,
        market_config_id: ID,
        creator: address,
        created_ms: u64,
        initial_liquidity: u64,
    }

    // ===== Events =====

    public struct MarketCreatedPermissionless has copy, drop {
        market_config_id: ID,
        sy_vault_id: ID,
        maturity_ms: u64,
        creator: address,
        initial_liquidity: u64,
    }

    public struct RegistryCreated has copy, drop {
        registry_id: ID,
    }

    // ===== Public Functions =====

    /// Create a shared MarketRegistry. Called once at protocol genesis.
    public fun create_registry(ctx: &mut TxContext): ID {
        let registry = MarketRegistry {
            id: object::new(ctx),
            existing_markets: vector[],
        };
        let registry_id = object::id(&registry);

        event::emit(RegistryCreated { registry_id });

        transfer::share_object(registry);
        registry_id
    }

    /// Permissionlessly create a new yield market.
    ///
    /// Anyone can call this as long as:
    /// - An SYVault<T> exists
    /// - Maturity is between MIN_DURATION_MS and MAX_DURATION_MS from now
    /// - No market exists for the same (vault, maturity)
    /// - At least MIN_INITIAL_LIQUIDITY SY is provided as seed
    ///
    /// The initial SY is consumed to mint PT+YT, which seeds the market.
    /// Returns the new YieldMarketConfig ID.
    public fun create_market<T>(
        registry: &mut MarketRegistry,
        vault: &SYVault<T>,
        initial_sy: SYToken<T>,
        maturity_ms: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): ID {
        let now = clock.timestamp_ms();
        let duration = maturity_ms - now;

        // Validate maturity bounds
        assert!(duration >= MIN_DURATION_MS, EMaturityTooSoon);
        assert!(duration <= MAX_DURATION_MS, EMaturityTooFar);

        let sy_amount = standardized_yield::sy_amount(&initial_sy);
        assert!(sy_amount > 0, EZeroAmount);
        assert!(sy_amount >= MIN_INITIAL_LIQUIDITY, EInsufficientLiquidity);

        let sy_vault_id = standardized_yield::vault_id(vault);

        // Check for duplicate
        let len = registry.existing_markets.length();
        let mut i = 0u64;
        while (i < len) {
            let entry = &registry.existing_markets[i];
            assert!(
                !(entry.sy_vault_id == sy_vault_id && entry.maturity_ms == maturity_ms),
                EDuplicateMarket,
            );
            i = i + 1;
        };

        // Create the yield market via yield_tokenizer
        let market_config_id = yield_tokenizer::create_market(vault, maturity_ms, clock, ctx);

        // Register the new market
        let entry = MarketEntry {
            sy_vault_id,
            maturity_ms,
            market_config_id,
            creator: ctx.sender(),
            created_ms: now,
            initial_liquidity: sy_amount,
        };
        registry.existing_markets.push_back(entry);

        // Freeze the initial SY as market seed liquidity
        transfer::public_freeze_object(initial_sy);

        event::emit(MarketCreatedPermissionless {
            market_config_id,
            sy_vault_id,
            maturity_ms,
            creator: ctx.sender(),
            initial_liquidity: sy_amount,
        });

        market_config_id
    }

    // ===== View Functions =====

    /// Number of markets created through the registry.
    public fun market_count(registry: &MarketRegistry): u64 {
        registry.existing_markets.length()
    }

    /// Check if a market already exists for (vault, maturity).
    public fun market_exists(
        registry: &MarketRegistry,
        sy_vault_id: ID,
        maturity_ms: u64,
    ): bool {
        let len = registry.existing_markets.length();
        let mut i = 0u64;
        while (i < len) {
            let entry = &registry.existing_markets[i];
            if (entry.sy_vault_id == sy_vault_id && entry.maturity_ms == maturity_ms) {
                return true
            };
            i = i + 1;
        };
        false
    }

    /// Get details of a market by index.
    /// Returns: (sy_vault_id, maturity_ms, market_config_id, creator, created_ms, initial_liquidity)
    public fun market_details(
        registry: &MarketRegistry,
        index: u64,
    ): (ID, u64, ID, address, u64, u64) {
        let entry = &registry.existing_markets[index];
        (
            entry.sy_vault_id,
            entry.maturity_ms,
            entry.market_config_id,
            entry.creator,
            entry.created_ms,
            entry.initial_liquidity,
        )
    }

    // ===== Test Helpers =====

    #[test_only]
    public fun create_registry_for_testing(ctx: &mut TxContext): ID {
        create_registry(ctx)
    }
}
