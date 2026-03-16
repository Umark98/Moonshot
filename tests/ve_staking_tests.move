#[test_only]
module crux::ve_staking_tests {
    use sui::test_scenario::{Self as ts};
    use sui::clock;
    use sui::coin;

    use crux::ve_staking::{Self, VeStakingPool, VeToken};

    public struct STAKE_COIN has drop {}

    const ADMIN: address = @0xAD;
    const USER: address = @0xB0B;

    const WAD: u128 = 1_000_000_000_000_000_000;
    const MIN_LOCK_MS: u64 = 7_889_400_000;       // 3 months
    const MAX_LOCK_MS: u64 = 126_230_400_000;      // 4 years
    const ONE_YEAR_MS: u64 = 31_557_600_000;

    #[test]
    fun test_create_pool() {
        let mut scenario = ts::begin(ADMIN);
        {
            ve_staking::create_pool_for_testing(scenario.ctx());
        };

        ts::next_tx(&mut scenario, ADMIN);
        {
            let pool = scenario.take_shared<VeStakingPool>();
            assert!(ve_staking::total_locked(&pool) == 0);
            assert!(ve_staking::total_ve_supply(&pool) == 0);
            ts::return_shared(pool);
        };
        scenario.end();
    }

    #[test]
    fun test_stake_min_lock() {
        let mut scenario = ts::begin(ADMIN);
        {
            ve_staking::create_pool_for_testing(scenario.ctx());
        };

        ts::next_tx(&mut scenario, USER);
        {
            let mut pool = scenario.take_shared<VeStakingPool>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(1000);

            let stake_coin = coin::mint_for_testing<STAKE_COIN>(1000, scenario.ctx());
            let ve_token = ve_staking::stake(&mut pool, stake_coin, MIN_LOCK_MS, &clk, scenario.ctx());

            assert!(ve_staking::total_locked(&pool) == 1000);
            assert!(ve_staking::total_ve_supply(&pool) > 0);

            // ve_amount = 1000 * MIN_LOCK_MS * WAD / MAX_LOCK_MS
            let expected_ve = (1000u128) * (MIN_LOCK_MS as u128) * WAD / (MAX_LOCK_MS as u128);
            assert!(ve_staking::position_ve_amount(&pool, 0) == expected_ve);

            sui::transfer::public_transfer(ve_token, USER);
            clk.destroy_for_testing();
            ts::return_shared(pool);
        };
        scenario.end();
    }

    #[test]
    fun test_stake_max_lock() {
        let mut scenario = ts::begin(ADMIN);
        {
            ve_staking::create_pool_for_testing(scenario.ctx());
        };

        ts::next_tx(&mut scenario, USER);
        {
            let mut pool = scenario.take_shared<VeStakingPool>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(1000);

            let stake_coin = coin::mint_for_testing<STAKE_COIN>(1000, scenario.ctx());
            let ve_token = ve_staking::stake(&mut pool, stake_coin, MAX_LOCK_MS, &clk, scenario.ctx());

            // Max lock: ve = locked_amount * WAD (1:1)
            let expected_ve = 1000u128 * WAD;
            assert!(ve_staking::position_ve_amount(&pool, 0) == expected_ve);

            sui::transfer::public_transfer(ve_token, USER);
            clk.destroy_for_testing();
            ts::return_shared(pool);
        };
        scenario.end();
    }

    #[test]
    fun test_unstake_after_expiry() {
        let mut scenario = ts::begin(ADMIN);
        {
            ve_staking::create_pool_for_testing(scenario.ctx());
        };

        ts::next_tx(&mut scenario, USER);
        {
            let mut pool = scenario.take_shared<VeStakingPool>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(1000);

            let stake_coin = coin::mint_for_testing<STAKE_COIN>(500, scenario.ctx());
            let ve_token = ve_staking::stake(&mut pool, stake_coin, MIN_LOCK_MS, &clk, scenario.ctx());

            sui::transfer::public_transfer(ve_token, USER);
            clk.destroy_for_testing();
            ts::return_shared(pool);
        };

        // Unstake after lock expires
        ts::next_tx(&mut scenario, USER);
        {
            let mut pool = scenario.take_shared<VeStakingPool>();
            let ve_token = scenario.take_from_sender<VeToken>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(1000 + MIN_LOCK_MS + 1);

            let unlocked = ve_staking::unstake(&mut pool, ve_token, &clk, scenario.ctx());
            assert!(unlocked == 500);
            assert!(ve_staking::total_locked(&pool) == 0);
            assert!(ve_staking::total_ve_supply(&pool) == 0);

            clk.destroy_for_testing();
            ts::return_shared(pool);
        };
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = 962)] // ELockNotExpired
    fun test_unstake_before_expiry() {
        let mut scenario = ts::begin(ADMIN);
        {
            ve_staking::create_pool_for_testing(scenario.ctx());
        };

        ts::next_tx(&mut scenario, USER);
        {
            let mut pool = scenario.take_shared<VeStakingPool>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(1000);

            let stake_coin = coin::mint_for_testing<STAKE_COIN>(500, scenario.ctx());
            let ve_token = ve_staking::stake(&mut pool, stake_coin, MIN_LOCK_MS, &clk, scenario.ctx());
            sui::transfer::public_transfer(ve_token, USER);
            clk.destroy_for_testing();
            ts::return_shared(pool);
        };

        ts::next_tx(&mut scenario, USER);
        {
            let mut pool = scenario.take_shared<VeStakingPool>();
            let ve_token = scenario.take_from_sender<VeToken>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(2000); // way before expiry

            ve_staking::unstake(&mut pool, ve_token, &clk, scenario.ctx());

            clk.destroy_for_testing();
            ts::return_shared(pool);
        };
        scenario.end();
    }

    #[test]
    fun test_extend_lock() {
        let mut scenario = ts::begin(ADMIN);
        {
            ve_staking::create_pool_for_testing(scenario.ctx());
        };

        ts::next_tx(&mut scenario, USER);
        {
            let mut pool = scenario.take_shared<VeStakingPool>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(1000);

            let stake_coin = coin::mint_for_testing<STAKE_COIN>(1000, scenario.ctx());
            let ve_token = ve_staking::stake(&mut pool, stake_coin, ONE_YEAR_MS, &clk, scenario.ctx());

            let old_ve = ve_staking::position_ve_amount(&pool, 0);

            // Extend to 2 years
            let new_end = 1000 + 2 * ONE_YEAR_MS;
            ve_staking::extend_lock(&mut pool, &ve_token, new_end, &clk, scenario.ctx());

            let new_ve = ve_staking::position_ve_amount(&pool, 0);
            // New ve should be ~2x old ve (2yr vs 1yr lock)
            assert!(new_ve > old_ve);

            assert!(ve_staking::lock_end_ms(&pool, 0) == new_end);

            sui::transfer::public_transfer(ve_token, USER);
            clk.destroy_for_testing();
            ts::return_shared(pool);
        };
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = 960)] // ELockTooShort
    fun test_lock_too_short() {
        let mut scenario = ts::begin(ADMIN);
        {
            ve_staking::create_pool_for_testing(scenario.ctx());
        };

        ts::next_tx(&mut scenario, USER);
        {
            let mut pool = scenario.take_shared<VeStakingPool>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(1000);

            let stake_coin = coin::mint_for_testing<STAKE_COIN>(1000, scenario.ctx());
            let ve_token = ve_staking::stake(&mut pool, stake_coin, 1000, &clk, scenario.ctx()); // 1 second, too short

            sui::transfer::public_transfer(ve_token, USER);
            clk.destroy_for_testing();
            ts::return_shared(pool);
        };
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = 961)] // ELockTooLong
    fun test_lock_too_long() {
        let mut scenario = ts::begin(ADMIN);
        {
            ve_staking::create_pool_for_testing(scenario.ctx());
        };

        ts::next_tx(&mut scenario, USER);
        {
            let mut pool = scenario.take_shared<VeStakingPool>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(1000);

            let stake_coin = coin::mint_for_testing<STAKE_COIN>(1000, scenario.ctx());
            let ve_token = ve_staking::stake(&mut pool, stake_coin, MAX_LOCK_MS + 1, &clk, scenario.ctx());

            sui::transfer::public_transfer(ve_token, USER);
            clk.destroy_for_testing();
            ts::return_shared(pool);
        };
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = 965)] // EZeroAmount
    fun test_stake_zero() {
        let mut scenario = ts::begin(ADMIN);
        {
            ve_staking::create_pool_for_testing(scenario.ctx());
        };

        ts::next_tx(&mut scenario, USER);
        {
            let mut pool = scenario.take_shared<VeStakingPool>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(1000);

            let stake_coin = coin::mint_for_testing<STAKE_COIN>(0, scenario.ctx());
            let ve_token = ve_staking::stake(&mut pool, stake_coin, MIN_LOCK_MS, &clk, scenario.ctx());

            sui::transfer::public_transfer(ve_token, USER);
            clk.destroy_for_testing();
            ts::return_shared(pool);
        };
        scenario.end();
    }

    #[test]
    fun test_multiple_stakers() {
        let mut scenario = ts::begin(ADMIN);
        {
            ve_staking::create_pool_for_testing(scenario.ctx());
        };

        ts::next_tx(&mut scenario, USER);
        {
            let mut pool = scenario.take_shared<VeStakingPool>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(1000);

            let coin1 = coin::mint_for_testing<STAKE_COIN>(1000, scenario.ctx());
            let ve1 = ve_staking::stake(&mut pool, coin1, ONE_YEAR_MS, &clk, scenario.ctx());

            let coin2 = coin::mint_for_testing<STAKE_COIN>(2000, scenario.ctx());
            let ve2 = ve_staking::stake(&mut pool, coin2, 2 * ONE_YEAR_MS, &clk, scenario.ctx());

            assert!(ve_staking::total_locked(&pool) == 3000);

            // ve2 should have more voting power (2x amount, 2x duration)
            let ve1_power = ve_staking::position_ve_amount(&pool, 0);
            let ve2_power = ve_staking::position_ve_amount(&pool, 1);
            assert!(ve2_power > ve1_power);

            sui::transfer::public_transfer(ve1, USER);
            sui::transfer::public_transfer(ve2, USER);
            clk.destroy_for_testing();
            ts::return_shared(pool);
        };
        scenario.end();
    }
}
