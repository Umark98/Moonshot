/// CRUX Governance Token — fixed supply of 1 billion CRUX.
/// Created via Sui's one-time witness pattern using `coin::create_currency`.
/// Handles initial distribution tracking and controlled minting via CRUXAdminCap.
module crux::crux_token {

    use sui::coin::{Self, TreasuryCap};
    use sui::event;
    use sui::url;

    // ===== Constants =====

    const TOTAL_SUPPLY: u64 = 1_000_000_000;
    const DECIMALS: u8 = 9;

    // ===== Error Codes =====

    const EExceedsAllocation: u64 = 980;
    const EZeroAmount: u64 = 981;

    // ===== Structs =====

    /// One-time witness for CRUX coin creation.
    public struct CRUX_TOKEN has drop {}

    /// Admin capability for controlled minting.
    public struct CRUXAdminCap has key, store {
        id: UID,
    }

    /// Shared object tracking token distribution allocations and minted supply.
    public struct TokenDistribution has key {
        id: UID,
        total_supply: u64,
        community_allocation: u64,
        team_allocation: u64,
        investor_allocation: u64,
        treasury_allocation: u64,
        liquidity_mining_allocation: u64,
        moonshots_allocation: u64,
        advisor_allocation: u64,
        minted_so_far: u64,
    }

    // ===== Events =====

    public struct TokensMinted has copy, drop {
        recipient: address,
        amount: u64,
        category: vector<u8>,
    }

    public struct TokenInitialized has copy, drop {
        total_supply: u64,
    }

    // ===== Init =====

    #[allow(deprecated_usage)]
    fun init(witness: CRUX_TOKEN, ctx: &mut TxContext) {
        let (treasury_cap, metadata) = coin::create_currency(
            witness,
            DECIMALS,
            b"CRUX",
            b"Crux",
            b"Crux protocol governance token",
            option::some(url::new_unsafe_from_bytes(b"https://crux.fi/icon.svg")),
            ctx,
        );

        transfer::public_freeze_object(metadata);

        transfer::public_transfer(treasury_cap, ctx.sender());

        transfer::transfer(
            CRUXAdminCap { id: object::new(ctx) },
            ctx.sender(),
        );

        let distribution = TokenDistribution {
            id: object::new(ctx),
            total_supply: TOTAL_SUPPLY,
            community_allocation: 350_000_000,      // 35%
            team_allocation: 200_000_000,            // 20%
            investor_allocation: 150_000_000,        // 15%
            treasury_allocation: 150_000_000,        // 15%
            liquidity_mining_allocation: 100_000_000, // 10%
            moonshots_allocation: 30_000_000,        //  3%
            advisor_allocation: 20_000_000,          //  2%
            minted_so_far: 0,
        };
        transfer::share_object(distribution);

        event::emit(TokenInitialized { total_supply: TOTAL_SUPPLY });
    }

    // ===== Functions =====

    /// Mint `amount` CRUX tokens and transfer them to `recipient`.
    /// Requires CRUXAdminCap and the protocol TreasuryCap.
    public fun mint(
        _admin: &CRUXAdminCap,
        treasury: &mut TreasuryCap<CRUX_TOKEN>,
        dist: &mut TokenDistribution,
        amount: u64,
        recipient: address,
        category: vector<u8>,
        ctx: &mut TxContext,
    ) {
        assert!(amount > 0, EZeroAmount);
        assert!(dist.minted_so_far + amount <= dist.total_supply, EExceedsAllocation);

        dist.minted_so_far = dist.minted_so_far + amount;

        let minted_coin = coin::mint(treasury, amount, ctx);
        transfer::public_transfer(minted_coin, recipient);

        event::emit(TokensMinted { recipient, amount, category });
    }

    // ===== View Functions =====

    /// Total fixed supply of CRUX tokens.
    public fun total_supply(dist: &TokenDistribution): u64 {
        dist.total_supply
    }

    /// Total CRUX tokens minted so far.
    public fun minted_so_far(dist: &TokenDistribution): u64 {
        dist.minted_so_far
    }

    // ===== Test Helpers =====

    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) {
        init(CRUX_TOKEN {}, ctx);
    }
}
