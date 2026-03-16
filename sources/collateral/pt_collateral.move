/// PT as Collateral — enables Principal Tokens to be used as collateral in lending
/// protocols. PTs are senior claims redeemable at maturity, making them ideal
/// collateral: their value has a known floor (par at maturity) and they carry no
/// liquidation risk from yield fluctuations.
///
/// This module manages collateral positions: deposit PT, borrow against it,
/// repay, and liquidate undercollateralised positions.
///
/// LTV (Loan-to-Value) is determined per market based on time-to-maturity:
///   - Far from maturity: lower LTV (more discount risk)
///   - Close to maturity: higher LTV (PT converges to par)
module crux::pt_collateral {

    use sui::clock::Clock;
    use sui::event;

    use crux::fixed_point;
    use crux::yield_tokenizer::{Self, YieldMarketConfig, PT};

    // ===== Constants =====

    const WAD: u128 = 1_000_000_000_000_000_000;

    /// Base LTV for PT collateral: 70%
    const BASE_LTV_WAD: u128 = 700_000_000_000_000_000;
    /// Maximum LTV (near maturity): 95%
    const MAX_LTV_WAD: u128 = 950_000_000_000_000_000;
    /// Liquidation threshold premium over LTV: +5%
    const LIQUIDATION_PREMIUM_WAD: u128 = 50_000_000_000_000_000;
    // ===== Error Codes =====

    const EZeroAmount: u64 = 1100;
    const EMarketExpired: u64 = 1101;
    const EExceedsLTV: u64 = 1102;
    const ENotLiquidatable: u64 = 1103;
    const EPositionNotFound: u64 = 1104;
    const ENotPositionOwner: u64 = 1105;
    const EInsufficientRepayment: u64 = 1106;

    // ===== Structs =====

    /// Shared object managing all PT collateral positions for a given market.
    public struct CollateralManager<phantom T> has key {
        id: UID,
        /// The yield market these positions are collateralised against
        market_config_id: ID,
        /// All active collateral positions
        positions: vector<CollateralPosition>,
        /// Next position ID
        next_position_id: u64,
        /// Total PT locked as collateral
        total_pt_locked: u64,
        /// Total SY borrowed against PT collateral
        total_sy_borrowed: u64,
    }

    /// A single collateral position.
    public struct CollateralPosition has store, drop, copy {
        position_id: u64,
        owner: address,
        /// Amount of PT deposited as collateral
        pt_collateral: u64,
        /// Amount of SY borrowed against this collateral
        sy_borrowed: u64,
        /// Timestamp when position was opened
        opened_ms: u64,
    }

    /// Receipt returned to the user on collateral deposit.
    public struct CollateralReceipt has key, store {
        id: UID,
        position_id: u64,
        manager_id: ID,
    }

    // ===== Events =====

    public struct CollateralDeposited has copy, drop {
        position_id: u64,
        owner: address,
        pt_amount: u64,
    }

    public struct Borrowed has copy, drop {
        position_id: u64,
        owner: address,
        sy_amount: u64,
    }

    public struct Repaid has copy, drop {
        position_id: u64,
        owner: address,
        sy_amount: u64,
    }

    public struct Liquidated has copy, drop {
        position_id: u64,
        liquidator: address,
        pt_seized: u64,
        debt_repaid: u64,
    }

    public struct CollateralWithdrawn has copy, drop {
        position_id: u64,
        owner: address,
        pt_amount: u64,
    }

    // ===== Public Functions =====

    /// Create a CollateralManager for a yield market.
    public fun create_manager<T>(
        config: &YieldMarketConfig<T>,
        ctx: &mut TxContext,
    ): ID {
        let market_config_id = yield_tokenizer::market_config_id(config);
        let manager = CollateralManager<T> {
            id: object::new(ctx),
            market_config_id,
            positions: vector[],
            next_position_id: 0,
            total_pt_locked: 0,
            total_sy_borrowed: 0,
        };
        let manager_id = object::id(&manager);
        transfer::share_object(manager);
        manager_id
    }

    /// Deposit PT as collateral and open a new position.
    public fun deposit_collateral<T>(
        manager: &mut CollateralManager<T>,
        pt: PT<T>,
        clock: &Clock,
        ctx: &mut TxContext,
    ): CollateralReceipt {
        let pt_amount = yield_tokenizer::pt_amount(&pt);
        assert!(pt_amount > 0, EZeroAmount);

        let position_id = manager.next_position_id;
        let owner = ctx.sender();

        let position = CollateralPosition {
            position_id,
            owner,
            pt_collateral: pt_amount,
            sy_borrowed: 0,
            opened_ms: clock.timestamp_ms(),
        };

        manager.positions.push_back(position);
        manager.next_position_id = position_id + 1;
        manager.total_pt_locked = manager.total_pt_locked + pt_amount;

        // Freeze the PT as collateral backing
        transfer::public_freeze_object(pt);

        event::emit(CollateralDeposited {
            position_id,
            owner,
            pt_amount,
        });

        CollateralReceipt {
            id: object::new(ctx),
            position_id,
            manager_id: object::id(manager),
        }
    }

    /// Borrow SY against deposited PT collateral.
    /// The borrow amount must not exceed the position's LTV limit.
    public fun borrow<T>(
        manager: &mut CollateralManager<T>,
        config: &YieldMarketConfig<T>,
        receipt: &CollateralReceipt,
        borrow_amount: u64,
        clock: &Clock,
        ctx: &TxContext,
    ) {
        assert!(!yield_tokenizer::is_expired(config), EMarketExpired);
        assert!(borrow_amount > 0, EZeroAmount);

        let (found, idx) = find_position(manager, receipt.position_id);
        assert!(found, EPositionNotFound);

        let position = &mut manager.positions[idx];
        assert!(position.owner == ctx.sender(), ENotPositionOwner);

        let new_borrowed = position.sy_borrowed + borrow_amount;
        let max_borrow = max_borrow_amount(
            position.pt_collateral,
            yield_tokenizer::maturity_ms(config),
            clock.timestamp_ms(),
            yield_tokenizer::total_duration_ms(config),
        );
        assert!(new_borrowed <= max_borrow, EExceedsLTV);

        position.sy_borrowed = new_borrowed;
        manager.total_sy_borrowed = manager.total_sy_borrowed + borrow_amount;

        event::emit(Borrowed {
            position_id: receipt.position_id,
            owner: position.owner,
            sy_amount: borrow_amount,
        });
    }

    /// Repay borrowed SY to reduce debt on a position.
    public fun repay<T>(
        manager: &mut CollateralManager<T>,
        receipt: &CollateralReceipt,
        repay_amount: u64,
        ctx: &TxContext,
    ) {
        assert!(repay_amount > 0, EZeroAmount);

        let (found, idx) = find_position(manager, receipt.position_id);
        assert!(found, EPositionNotFound);

        let position = &mut manager.positions[idx];
        assert!(position.owner == ctx.sender(), ENotPositionOwner);

        let actual_repay = fixed_point::min_u64(repay_amount, position.sy_borrowed);
        position.sy_borrowed = position.sy_borrowed - actual_repay;
        manager.total_sy_borrowed = manager.total_sy_borrowed - actual_repay;

        event::emit(Repaid {
            position_id: receipt.position_id,
            owner: position.owner,
            sy_amount: actual_repay,
        });
    }

    /// Withdraw PT collateral after fully repaying debt.
    /// Returns the PT amount withdrawn (actual PT object transfer handled off-chain
    /// in production; here we track the accounting).
    public fun withdraw_collateral<T>(
        manager: &mut CollateralManager<T>,
        receipt: CollateralReceipt,
        ctx: &TxContext,
    ): u64 {
        let CollateralReceipt { id, position_id, manager_id: _ } = receipt;
        object::delete(id);

        let (found, idx) = find_position(manager, position_id);
        assert!(found, EPositionNotFound);

        let position = manager.positions[idx];
        assert!(position.owner == ctx.sender(), ENotPositionOwner);
        assert!(position.sy_borrowed == 0, EInsufficientRepayment);

        let pt_amount = position.pt_collateral;
        manager.total_pt_locked = manager.total_pt_locked - pt_amount;
        manager.positions.remove(idx);

        event::emit(CollateralWithdrawn {
            position_id,
            owner: position.owner,
            pt_amount,
        });

        pt_amount
    }

    /// Liquidate an undercollateralised position.
    /// Anyone can call this if the position's debt exceeds the liquidation threshold.
    /// The liquidator repays the debt and receives the PT collateral + bonus.
    public fun liquidate<T>(
        manager: &mut CollateralManager<T>,
        config: &YieldMarketConfig<T>,
        position_id: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): (u64, u64) {
        let (found, idx) = find_position(manager, position_id);
        assert!(found, EPositionNotFound);

        let position = manager.positions[idx];

        // Check if position is liquidatable
        let liq_threshold = liquidation_threshold(
            position.pt_collateral,
            yield_tokenizer::maturity_ms(config),
            clock.timestamp_ms(),
            yield_tokenizer::total_duration_ms(config),
        );
        assert!(position.sy_borrowed > liq_threshold, ENotLiquidatable);

        let debt_repaid = position.sy_borrowed;
        // PT seized = collateral amount (liquidator gets all)
        let pt_seized = position.pt_collateral;

        manager.total_pt_locked = manager.total_pt_locked - pt_seized;
        manager.total_sy_borrowed = manager.total_sy_borrowed - debt_repaid;
        manager.positions.remove(idx);

        event::emit(Liquidated {
            position_id,
            liquidator: ctx.sender(),
            pt_seized,
            debt_repaid,
        });

        (pt_seized, debt_repaid)
    }

    // ===== View Functions =====

    /// Calculate the current LTV for PT collateral based on time-to-maturity.
    /// Linearly interpolates from BASE_LTV (far) to MAX_LTV (at maturity).
    public fun current_ltv_wad(
        maturity_ms: u64,
        now_ms: u64,
        total_duration_ms: u64,
    ): u128 {
        if (now_ms >= maturity_ms) return MAX_LTV_WAD;
        let time_remaining = maturity_ms - now_ms;
        let elapsed_ratio = fixed_point::wad_div(
            ((total_duration_ms - time_remaining) as u128) * WAD,
            (total_duration_ms as u128) * WAD,
        );
        // LTV = BASE + (MAX - BASE) * elapsed_ratio
        let ltv_range = MAX_LTV_WAD - BASE_LTV_WAD;
        BASE_LTV_WAD + fixed_point::wad_mul(ltv_range, elapsed_ratio)
    }

    /// Maximum borrow amount for a given PT collateral amount.
    public fun max_borrow_amount(
        pt_amount: u64,
        maturity_ms: u64,
        now_ms: u64,
        total_duration_ms: u64,
    ): u64 {
        let ltv = current_ltv_wad(maturity_ms, now_ms, total_duration_ms);
        fixed_point::from_wad(
            fixed_point::wad_mul(fixed_point::to_wad(pt_amount), ltv)
        )
    }

    /// Liquidation threshold for a position.
    fun liquidation_threshold(
        pt_amount: u64,
        maturity_ms: u64,
        now_ms: u64,
        total_duration_ms: u64,
    ): u64 {
        let ltv = current_ltv_wad(maturity_ms, now_ms, total_duration_ms);
        let threshold = ltv + LIQUIDATION_PREMIUM_WAD;
        let threshold = fixed_point::min_u128(threshold, WAD);
        fixed_point::from_wad(
            fixed_point::wad_mul(fixed_point::to_wad(pt_amount), threshold)
        )
    }

    /// Total PT locked as collateral across all positions.
    public fun total_pt_locked<T>(manager: &CollateralManager<T>): u64 {
        manager.total_pt_locked
    }

    /// Total SY borrowed against PT collateral.
    public fun total_sy_borrowed<T>(manager: &CollateralManager<T>): u64 {
        manager.total_sy_borrowed
    }

    /// Number of active positions.
    public fun position_count<T>(manager: &CollateralManager<T>): u64 {
        manager.positions.length()
    }

    /// Get position details: (pt_collateral, sy_borrowed, opened_ms)
    public fun position_details<T>(
        manager: &CollateralManager<T>,
        position_id: u64,
    ): (u64, u64, u64) {
        let (found, idx) = find_position(manager, position_id);
        assert!(found, EPositionNotFound);
        let pos = &manager.positions[idx];
        (pos.pt_collateral, pos.sy_borrowed, pos.opened_ms)
    }

    // ===== Internal =====

    fun find_position<T>(
        manager: &CollateralManager<T>,
        position_id: u64,
    ): (bool, u64) {
        let mut i = 0;
        let len = manager.positions.length();
        while (i < len) {
            if (manager.positions[i].position_id == position_id) {
                return (true, i)
            };
            i = i + 1;
        };
        (false, len)
    }
}
