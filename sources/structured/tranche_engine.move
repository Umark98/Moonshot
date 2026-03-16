/// Tranche Engine — structured yield products for Crux Protocol.
/// Creates senior (fixed yield, protected) and junior (leveraged yield, first-loss)
/// tranches from yield-bearing assets.
///
/// Waterfall mechanic:
///   1. At maturity, actual yield is calculated
///   2. Senior tranche receives their target rate first (guaranteed up to available yield)
///   3. Junior tranche receives all remaining yield (leveraged exposure)
///   4. If yield < senior target, junior absorbs losses first
///
/// Example with 80/20 split:
///   - 800 SY senior (target 5%) + 200 SY junior
///   - If yield = 8%: Senior gets 5% (40 SY), Junior gets remainder (40 SY = 20% return)
///   - If yield = 2%: Senior gets 2% (20 SY), Junior gets 0 (first-loss)
module crux::tranche_engine {

    use sui::clock::Clock;
    use sui::event;

    use crux::fixed_point;

    // ===== Constants =====

    const WAD: u128 = 1_000_000_000_000_000_000;

    // ===== Error Codes =====

    const ETrancheExpired: u64 = 1000;
    const ETrancheNotExpired: u64 = 1001;
    const EAlreadySettled: u64 = 1002;
    const ENotSettled: u64 = 1003;
    const EZeroDeposit: u64 = 1004;
    const EMaxLeverageExceeded: u64 = 1005;
    const EWrongVault: u64 = 1006;

    // ===== Structs =====

    /// Shared object: one per tranche series (asset + maturity)
    public struct TrancheVault has key {
        id: UID,
        /// Total SY deposited across both tranches
        total_sy_deposited: u64,
        /// Senior tranche: fixed yield target
        senior_supply: u64,
        senior_target_rate_wad: u128,  // e.g., 5% = 50_000_000_000_000_000
        /// Junior tranche: leveraged variable yield
        junior_supply: u64,
        /// Maturity timestamp
        maturity_ms: u64,
        /// Maximum senior:junior ratio (e.g., 4 means 80% senior max)
        max_senior_junior_ratio: u64,
        /// Whether waterfall settlement has occurred
        is_settled: bool,
        /// Actual yield at settlement (SY units)
        settlement_total_yield: u64,
        /// Senior payout per unit at settlement (WAD)
        senior_payout_per_unit_wad: u128,
        /// Junior payout per unit at settlement (WAD)
        junior_payout_per_unit_wad: u128,
    }

    /// Owned: senior tranche token
    public struct SeniorTranche has key, store {
        id: UID,
        amount: u64,
        vault_id: ID,
    }

    /// Owned: junior tranche token
    public struct JuniorTranche has key, store {
        id: UID,
        amount: u64,
        vault_id: ID,
    }

    // ===== Events =====

    public struct TrancheVaultCreated has copy, drop {
        vault_id: ID,
        maturity_ms: u64,
        senior_target_rate_wad: u128,
        max_senior_junior_ratio: u64,
    }

    public struct SeniorDeposited has copy, drop {
        vault_id: ID,
        depositor: address,
        amount: u64,
    }

    public struct JuniorDeposited has copy, drop {
        vault_id: ID,
        depositor: address,
        amount: u64,
    }

    public struct TrancheSettled has copy, drop {
        vault_id: ID,
        total_yield: u64,
        senior_payout_wad: u128,
        junior_payout_wad: u128,
    }

    // ===== Functions =====

    /// Create a new tranche vault for structured yield.
    public fun create_tranche_vault(
        maturity_ms: u64,
        senior_target_rate_wad: u128,
        max_senior_junior_ratio: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): ID {
        assert!(maturity_ms > clock.timestamp_ms(), ETrancheExpired);

        let vault = TrancheVault {
            id: object::new(ctx),
            total_sy_deposited: 0,
            senior_supply: 0,
            senior_target_rate_wad,
            junior_supply: 0,
            maturity_ms,
            max_senior_junior_ratio,
            is_settled: false,
            settlement_total_yield: 0,
            senior_payout_per_unit_wad: 0,
            junior_payout_per_unit_wad: 0,
        };

        let vault_id = object::id(&vault);

        event::emit(TrancheVaultCreated {
            vault_id,
            maturity_ms,
            senior_target_rate_wad,
            max_senior_junior_ratio,
        });

        transfer::share_object(vault);
        vault_id
    }

    /// Deposit into the senior tranche (fixed yield target).
    public fun deposit_senior(
        vault: &mut TrancheVault,
        sy_amount: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): SeniorTranche {
        assert!(!vault.is_settled, EAlreadySettled);
        assert!(clock.timestamp_ms() < vault.maturity_ms, ETrancheExpired);
        assert!(sy_amount > 0, EZeroDeposit);

        // Check leverage ratio: senior / junior <= max_ratio
        let new_senior = vault.senior_supply + sy_amount;
        if (vault.junior_supply > 0) {
            assert!(
                new_senior / vault.junior_supply <= vault.max_senior_junior_ratio,
                EMaxLeverageExceeded,
            );
        };

        vault.senior_supply = new_senior;
        vault.total_sy_deposited = vault.total_sy_deposited + sy_amount;

        let vault_id = object::id(vault);

        event::emit(SeniorDeposited {
            vault_id,
            depositor: ctx.sender(),
            amount: sy_amount,
        });

        SeniorTranche {
            id: object::new(ctx),
            amount: sy_amount,
            vault_id,
        }
    }

    /// Deposit into the junior tranche (leveraged yield, first-loss).
    public fun deposit_junior(
        vault: &mut TrancheVault,
        sy_amount: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): JuniorTranche {
        assert!(!vault.is_settled, EAlreadySettled);
        assert!(clock.timestamp_ms() < vault.maturity_ms, ETrancheExpired);
        assert!(sy_amount > 0, EZeroDeposit);

        vault.junior_supply = vault.junior_supply + sy_amount;
        vault.total_sy_deposited = vault.total_sy_deposited + sy_amount;

        let vault_id = object::id(vault);

        event::emit(JuniorDeposited {
            vault_id,
            depositor: ctx.sender(),
            amount: sy_amount,
        });

        JuniorTranche {
            id: object::new(ctx),
            amount: sy_amount,
            vault_id,
        }
    }

    /// Settle the tranche vault at maturity.
    /// Calculates the waterfall distribution.
    /// `actual_yield_sy` is the total yield generated by the underlying during the period.
    public fun settle(
        vault: &mut TrancheVault,
        actual_yield_sy: u64,
        clock: &Clock,
    ) {
        assert!(clock.timestamp_ms() >= vault.maturity_ms, ETrancheNotExpired);
        assert!(!vault.is_settled, EAlreadySettled);

        vault.is_settled = true;
        vault.settlement_total_yield = actual_yield_sy;

        // Calculate duration fraction for pro-rata rate
        // For simplicity, we use the full target rate (assumes maturity = 1 year scaled)
        // In production, this would be time-weighted

        // Senior target payout (in SY units)
        let senior_target_yield = fixed_point::from_wad(
            fixed_point::wad_mul(
                fixed_point::to_wad(vault.senior_supply),
                vault.senior_target_rate_wad,
            )
        );

        if (actual_yield_sy >= senior_target_yield) {
            // Enough yield: senior gets target, junior gets remainder
            // Senior payout per unit = 1.0 + target_rate (principal + yield)
            vault.senior_payout_per_unit_wad = WAD + vault.senior_target_rate_wad;

            // Junior gets remaining yield
            let junior_yield = actual_yield_sy - senior_target_yield;
            if (vault.junior_supply > 0) {
                vault.junior_payout_per_unit_wad = WAD + fixed_point::wad_div(
                    fixed_point::to_wad(junior_yield),
                    fixed_point::to_wad(vault.junior_supply),
                );
            } else {
                vault.junior_payout_per_unit_wad = 0;
            };
        } else {
            // Insufficient yield: senior gets all available, junior gets nothing
            if (vault.senior_supply > 0) {
                vault.senior_payout_per_unit_wad = WAD + fixed_point::wad_div(
                    fixed_point::to_wad(actual_yield_sy),
                    fixed_point::to_wad(vault.senior_supply),
                );
            };
            // Junior absorbs the loss — they only get principal back minus shortfall
            // In a more severe case, junior could lose principal too
            vault.junior_payout_per_unit_wad = WAD; // Just principal, no yield
        };

        event::emit(TrancheSettled {
            vault_id: object::id(vault),
            total_yield: actual_yield_sy,
            senior_payout_wad: vault.senior_payout_per_unit_wad,
            junior_payout_wad: vault.junior_payout_per_unit_wad,
        });
    }

    /// Redeem senior tranche tokens after settlement.
    /// Returns the SY amount the user should receive.
    public fun redeem_senior(
        vault: &TrancheVault,
        tranche: SeniorTranche,
    ): u64 {
        assert!(vault.is_settled, ENotSettled);

        let SeniorTranche { id, amount, vault_id } = tranche;
        assert!(vault_id == object::id(vault), EWrongVault);
        object::delete(id);

        // Payout = amount * senior_payout_per_unit / WAD
        fixed_point::from_wad(
            fixed_point::wad_mul(
                fixed_point::to_wad(amount),
                vault.senior_payout_per_unit_wad,
            )
        )
    }

    /// Redeem junior tranche tokens after settlement.
    public fun redeem_junior(
        vault: &TrancheVault,
        tranche: JuniorTranche,
    ): u64 {
        assert!(vault.is_settled, ENotSettled);

        let JuniorTranche { id, amount, vault_id } = tranche;
        assert!(vault_id == object::id(vault), EWrongVault);
        object::delete(id);

        fixed_point::from_wad(
            fixed_point::wad_mul(
                fixed_point::to_wad(amount),
                vault.junior_payout_per_unit_wad,
            )
        )
    }

    // ===== View Functions =====

    /// Get the current senior tranche APY target
    public fun senior_target_rate(vault: &TrancheVault): u128 {
        vault.senior_target_rate_wad
    }

    /// Get current junior leverage factor
    public fun junior_leverage(vault: &TrancheVault): u128 {
        if (vault.junior_supply == 0) return 0;
        fixed_point::wad_div(
            fixed_point::to_wad(vault.total_sy_deposited),
            fixed_point::to_wad(vault.junior_supply),
        )
    }

    /// Get total SY deposited
    public fun total_deposited(vault: &TrancheVault): u64 {
        vault.total_sy_deposited
    }

    /// Get senior supply
    public fun senior_supply(vault: &TrancheVault): u64 {
        vault.senior_supply
    }

    /// Get junior supply
    public fun junior_supply(vault: &TrancheVault): u64 {
        vault.junior_supply
    }

    /// Check if settled
    public fun is_settled(vault: &TrancheVault): bool {
        vault.is_settled
    }
}
