/// veCRUX Vote-Escrowed Staking — users lock CRUX tokens for 1–4 years to
/// receive veCRUX (voting power + fee sharing). Longer lock = more voting
/// power (linear scaling). Used for governance votes and protocol fee
/// distribution.
module crux::ve_staking {

    use sui::clock::Clock;
    use sui::event;
    use sui::coin::Coin;

    // ===== Constants =====

    const WAD: u128 = 1_000_000_000_000_000_000;

    /// Minimum lock duration: 3 months
    const MIN_LOCK_MS: u64 = 7_889_400_000;
    /// Maximum lock duration: 4 years
    const MAX_LOCK_MS: u64 = 126_230_400_000;
    /// Milliseconds per year (365.25 days)
    #[allow(unused_const)]
    const MS_PER_YEAR: u64 = 31_557_600_000;

    // ===== Error Codes =====

    const ELockTooShort: u64      = 960;
    const ELockTooLong: u64       = 961;
    const ELockNotExpired: u64    = 962;
    const EPositionNotFound: u64  = 963;
    const ENotPositionOwner: u64  = 964;
    const EZeroAmount: u64        = 965;

    // ===== Structs =====

    /// Shared object managing all veCRUX stake positions.
    public struct VeStakingPool has key {
        id: UID,
        /// Total CRUX tokens currently locked
        total_locked: u64,
        /// Sum of all weighted veCRUX positions, in WAD
        total_ve_supply: u128,
        /// Monotonically increasing position ID counter
        next_position_id: u64,
        /// All active stake positions
        positions: vector<StakePosition>,
    }

    /// A single staker's locked position.
    public struct StakePosition has store, drop, copy {
        position_id: u64,
        owner: address,
        /// Amount of CRUX locked
        locked_amount: u64,
        /// Timestamp (ms) when the lock was created or last extended
        lock_start_ms: u64,
        /// Timestamp (ms) when the lock expires
        lock_end_ms: u64,
        /// Voting power = locked_amount * (duration / MAX_LOCK), in WAD
        ve_amount_wad: u128,
    }

    /// Owned receipt object returned to the staker on lock creation.
    public struct VeToken has key, store {
        id: UID,
        position_id: u64,
        pool_id: ID,
    }

    // ===== Events =====

    public struct Staked has copy, drop {
        position_id: u64,
        owner: address,
        locked_amount: u64,
        lock_duration_ms: u64,
        ve_amount_wad: u128,
    }

    public struct Unstaked has copy, drop {
        position_id: u64,
        owner: address,
        unlocked_amount: u64,
    }

    public struct LockExtended has copy, drop {
        position_id: u64,
        new_end_ms: u64,
        new_ve_amount_wad: u128,
    }

    // ===== Public Functions =====

    /// Create a shared VeStakingPool. Returns the pool's object ID.
    public fun create_pool(ctx: &mut TxContext): ID {
        let pool = VeStakingPool {
            id: object::new(ctx),
            total_locked: 0,
            total_ve_supply: 0,
            next_position_id: 0,
            positions: vector[],
        };
        let pool_id = object::id(&pool);
        transfer::share_object(pool);
        pool_id
    }

    /// Lock `coin` for `lock_duration_ms` milliseconds and receive a VeToken.
    /// Voting power scales linearly: ve = locked * (duration / MAX_LOCK_MS), in WAD.
    public fun stake<T>(
        pool: &mut VeStakingPool,
        coin: Coin<T>,
        lock_duration_ms: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): VeToken {
        let locked_amount = coin.value();
        assert!(locked_amount > 0, EZeroAmount);
        assert!(lock_duration_ms >= MIN_LOCK_MS, ELockTooShort);
        assert!(lock_duration_ms <= MAX_LOCK_MS, ELockTooLong);

        let now = clock.timestamp_ms();
        let lock_end_ms = now + lock_duration_ms;

        let ve_amount_wad = compute_ve_amount(locked_amount, lock_duration_ms);

        let position_id = pool.next_position_id;
        let owner = ctx.sender();

        let position = StakePosition {
            position_id,
            owner,
            locked_amount,
            lock_start_ms: now,
            lock_end_ms,
            ve_amount_wad,
        };

        pool.positions.push_back(position);
        pool.next_position_id = position_id + 1;
        pool.total_locked = pool.total_locked + locked_amount;
        pool.total_ve_supply = pool.total_ve_supply + ve_amount_wad;

        // Freeze the coin to represent tokens being locked in the protocol.
        transfer::public_freeze_object(coin);

        event::emit(Staked {
            position_id,
            owner,
            locked_amount,
            lock_duration_ms,
            ve_amount_wad,
        });

        VeToken {
            id: object::new(ctx),
            position_id,
            pool_id: object::id(pool),
        }
    }

    /// Unlock tokens after the lock has expired. Burns the VeToken and returns
    /// the originally locked amount (informational; the frozen coin is noted).
    public fun unstake(
        pool: &mut VeStakingPool,
        ve_token: VeToken,
        clock: &Clock,
        ctx: &TxContext,
    ): u64 {
        let VeToken { id, position_id, pool_id: _ } = ve_token;
        object::delete(id);

        let (found, idx) = find_position_index(pool, position_id);
        assert!(found, EPositionNotFound);

        let position = pool.positions[idx];
        assert!(position.owner == ctx.sender(), ENotPositionOwner);
        assert!(clock.timestamp_ms() >= position.lock_end_ms, ELockNotExpired);

        let unlocked_amount = position.locked_amount;

        pool.total_locked = pool.total_locked - unlocked_amount;
        pool.total_ve_supply = pool.total_ve_supply - position.ve_amount_wad;
        pool.positions.remove(idx);

        event::emit(Unstaked {
            position_id,
            owner: position.owner,
            unlocked_amount,
        });

        unlocked_amount
    }

    /// Extend an existing lock to a later end timestamp.
    /// `new_end_ms` must be strictly after the current `lock_end_ms`.
    /// Recomputes and updates ve_amount_wad accordingly.
    public fun extend_lock(
        pool: &mut VeStakingPool,
        ve_token: &VeToken,
        new_end_ms: u64,
        clock: &Clock,
    ) {
        let (found, idx) = find_position_index(pool, ve_token.position_id);
        assert!(found, EPositionNotFound);

        let position = &mut pool.positions[idx];

        // New end must be further in the future than the current end.
        assert!(new_end_ms > position.lock_end_ms, ELockTooShort);

        let now = clock.timestamp_ms();
        let new_duration_ms = new_end_ms - now;
        assert!(new_duration_ms <= MAX_LOCK_MS, ELockTooLong);

        // Remove old voting power contribution before updating.
        pool.total_ve_supply = pool.total_ve_supply - position.ve_amount_wad;

        let new_ve_amount_wad = compute_ve_amount(position.locked_amount, new_duration_ms);
        position.lock_end_ms = new_end_ms;
        position.ve_amount_wad = new_ve_amount_wad;

        pool.total_ve_supply = pool.total_ve_supply + new_ve_amount_wad;

        event::emit(LockExtended {
            position_id: ve_token.position_id,
            new_end_ms,
            new_ve_amount_wad,
        });
    }

    // ===== View Functions =====

    /// Total CRUX tokens locked in the pool.
    public fun total_locked(pool: &VeStakingPool): u64 {
        pool.total_locked
    }

    /// Total veCRUX supply (sum of all weighted positions), in WAD.
    public fun total_ve_supply(pool: &VeStakingPool): u128 {
        pool.total_ve_supply
    }

    /// Voting power (ve_amount_wad) for a given position ID.
    public fun position_ve_amount(pool: &VeStakingPool, position_id: u64): u128 {
        let (found, idx) = find_position_index(pool, position_id);
        assert!(found, EPositionNotFound);
        pool.positions[idx].ve_amount_wad
    }

    /// Lock expiry timestamp (ms) for a given position ID.
    public fun lock_end_ms(pool: &VeStakingPool, position_id: u64): u64 {
        let (found, idx) = find_position_index(pool, position_id);
        assert!(found, EPositionNotFound);
        pool.positions[idx].lock_end_ms
    }

    // ===== Internal Helpers =====

    /// Linear scan for a position by ID.
    /// Returns (true, index) if found, (false, positions.length()) if not found.
    fun find_position_index(pool: &VeStakingPool, position_id: u64): (bool, u64) {
        let mut i = 0;
        let len = pool.positions.length();
        while (i < len) {
            if (pool.positions[i].position_id == position_id) {
                return (true, i)
            };
            i = i + 1;
        };
        (false, len)
    }

    /// Compute veCRUX amount in WAD.
    /// ve_wad = locked_amount * duration_ms * WAD / MAX_LOCK_MS
    /// A full 4-year lock on `locked_amount` tokens yields exactly
    /// `locked_amount * WAD` voting power (i.e. 1 veCRUX per CRUX at max lock).
    fun compute_ve_amount(locked_amount: u64, duration_ms: u64): u128 {
        (locked_amount as u128) * (duration_ms as u128) * WAD / (MAX_LOCK_MS as u128)
    }

    // ===== Test Helpers =====

    #[test_only]
    public fun create_pool_for_testing(ctx: &mut TxContext): ID {
        create_pool(ctx)
    }
}
