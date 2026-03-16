/// Fee Collector — accumulates and distributes protocol fees for Crux.
/// Revenue sources: AMM trading fees (20% protocol share), YT interest spread,
/// tranche origination fees, flash mint fees.
///
/// Distribution: fees flow to veCRUX stakers and the protocol treasury.
module crux::fee_collector {

    use sui::balance::{Self, Balance};
    use sui::coin::{Self, Coin};
    use sui::event;

    // ===== Constants =====

    const WAD: u128 = 1_000_000_000_000_000_000;

    /// Distribution: 80% to veCRUX stakers, 20% to treasury
    const STAKER_SHARE_WAD: u128 = 800_000_000_000_000_000; // 0.80

    // ===== Error Codes =====

    const EInsufficientFees: u64 = 901;

    // ===== Structs =====

    /// Admin capability for fee management
    public struct FeeAdminCap has key, store {
        id: UID,
    }

    /// Shared object: accumulates fees for a specific coin type.
    public struct FeeVault<phantom T> has key {
        id: UID,
        /// Accumulated fees awaiting distribution
        pending_fees: Balance<T>,
        /// Total fees ever collected
        total_collected: u64,
        /// Total fees distributed to stakers
        total_distributed_stakers: u64,
        /// Total fees sent to treasury
        total_distributed_treasury: u64,
        /// Treasury address
        treasury: address,
    }

    // ===== Events =====

    #[allow(unused_field)]
    public struct FeesCollected has copy, drop {
        coin_type: vector<u8>,
        amount: u64,
        total_collected: u64,
    }

    public struct FeesDistributed has copy, drop {
        staker_amount: u64,
        treasury_amount: u64,
    }

    // ===== Init =====

    fun init(ctx: &mut TxContext) {
        transfer::transfer(
            FeeAdminCap { id: object::new(ctx) },
            ctx.sender(),
        );
    }

    // ===== Functions =====

    /// Create a fee vault for a specific coin type.
    public fun create_vault<T>(
        _admin: &FeeAdminCap,
        treasury: address,
        ctx: &mut TxContext,
    ) {
        let vault = FeeVault<T> {
            id: object::new(ctx),
            pending_fees: balance::zero<T>(),
            total_collected: 0,
            total_distributed_stakers: 0,
            total_distributed_treasury: 0,
            treasury,
        };
        transfer::share_object(vault);
    }

    /// Deposit fees into the vault. Called by AMM, tokenizer, etc.
    public fun collect_fees<T>(
        vault: &mut FeeVault<T>,
        fee_coin: Coin<T>,
        coin_type_name: vector<u8>,
    ) {
        let amount = fee_coin.value();
        vault.total_collected = vault.total_collected + amount;
        let fee_balance = fee_coin.into_balance();
        vault.pending_fees.join(fee_balance);

        event::emit(FeesCollected {
            coin_type: coin_type_name,
            amount,
            total_collected: vault.total_collected,
        });
    }

    /// Distribute accumulated fees to stakers and treasury.
    /// Returns the staker portion as a Coin (to be distributed to veCRUX staking contract).
    public fun distribute_fees<T>(
        _admin: &FeeAdminCap,
        vault: &mut FeeVault<T>,
        ctx: &mut TxContext,
    ): Coin<T> {
        let total = vault.pending_fees.value();
        assert!(total > 0, EInsufficientFees);

        // Calculate shares
        let staker_amount = ((total as u128) * STAKER_SHARE_WAD / WAD as u64);
        let treasury_amount = total - staker_amount;

        // Send treasury share
        if (treasury_amount > 0) {
            let treasury_balance = vault.pending_fees.split(treasury_amount);
            let treasury_coin = coin::from_balance(treasury_balance, ctx);
            transfer::public_transfer(treasury_coin, vault.treasury);
            vault.total_distributed_treasury = vault.total_distributed_treasury + treasury_amount;
        };

        // Return staker share (caller sends to veCRUX staking contract)
        let staker_balance = vault.pending_fees.split(staker_amount);
        vault.total_distributed_stakers = vault.total_distributed_stakers + staker_amount;

        event::emit(FeesDistributed {
            staker_amount,
            treasury_amount,
        });

        coin::from_balance(staker_balance, ctx)
    }

    // ===== View Functions =====

    /// Get total pending fees
    public fun pending_fees<T>(vault: &FeeVault<T>): u64 {
        vault.pending_fees.value()
    }

    // ===== Test Helpers =====

    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) {
        init(ctx);
    }

    /// Get total fees ever collected
    public fun total_collected<T>(vault: &FeeVault<T>): u64 {
        vault.total_collected
    }
}
