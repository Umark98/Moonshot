#[test_only]
module crux::gauge_voting_tests {
    use sui::test_scenario::{Self as ts};
    use sui::clock;
    use sui::coin;

    use crux::gauge_voting::{Self, GaugeController, VoteRecord};
    use crux::ve_staking::{Self, VeStakingPool, VeToken};

    public struct STAKE_COIN has drop {}

    const ADMIN: address = @0xAD;
    const VOTER1: address = @0xB0B;
    const VOTER2: address = @0xCAFE;

    const WAD: u128 = 1_000_000_000_000_000_000;
    const EPOCH_DURATION_MS: u64 = 604_800_000; // 7 days

    #[test]
    fun test_create_controller() {
        let mut scenario = ts::begin(ADMIN);
        {
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(1000);
            gauge_voting::create_controller(&clk, scenario.ctx());
            clk.destroy_for_testing();
        };

        ts::next_tx(&mut scenario, ADMIN);
        {
            let controller = scenario.take_shared<GaugeController>();
            assert!(gauge_voting::current_epoch(&controller) == 0);
            assert!(gauge_voting::gauge_count(&controller) == 0);
            assert!(gauge_voting::total_votes(&controller) == 0);
            assert!(gauge_voting::emissions_per_epoch(&controller) == 50_000);
            ts::return_shared(controller);
        };
        scenario.end();
    }

    #[test]
    fun test_add_gauge() {
        let mut scenario = ts::begin(ADMIN);
        {
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(1000);
            gauge_voting::create_controller(&clk, scenario.ctx());
            clk.destroy_for_testing();
        };

        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut controller = scenario.take_shared<GaugeController>();
            let pool_id = object::id_from_address(@0x1);
            gauge_voting::add_gauge(&mut controller, pool_id);
            assert!(gauge_voting::gauge_count(&controller) == 1);

            let pool_id2 = object::id_from_address(@0x2);
            gauge_voting::add_gauge(&mut controller, pool_id2);
            assert!(gauge_voting::gauge_count(&controller) == 2);

            ts::return_shared(controller);
        };
        scenario.end();
    }

    #[test]
    fun test_cast_vote() {
        let mut scenario = ts::begin(ADMIN);
        {
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(1000);
            gauge_voting::create_controller(&clk, scenario.ctx());
            ve_staking::create_pool_for_testing(scenario.ctx());
            clk.destroy_for_testing();
        };

        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut controller = scenario.take_shared<GaugeController>();
            let pool_id = object::id_from_address(@0x1);
            gauge_voting::add_gauge(&mut controller, pool_id);
            ts::return_shared(controller);
        };

        ts::next_tx(&mut scenario, VOTER1);
        {
            let mut controller = scenario.take_shared<GaugeController>();
            let mut pool = scenario.take_shared<VeStakingPool>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(2000);

            let stake_coin = coin::mint_for_testing<STAKE_COIN>(100, scenario.ctx());
            let ve_token = ve_staking::stake(&mut pool, stake_coin, 126_230_400_000, &clk, scenario.ctx());

            let record = gauge_voting::cast_vote(&mut controller, &pool, &ve_token, 0, &clk, scenario.ctx());

            assert!(gauge_voting::total_votes(&controller) > 0);

            sui::transfer::public_transfer(ve_token, VOTER1);
            sui::transfer::public_transfer(record, VOTER1);
            clk.destroy_for_testing();
            ts::return_shared(pool);
            ts::return_shared(controller);
        };
        scenario.end();
    }

    #[test]
    fun test_gauge_share_calculation() {
        let mut scenario = ts::begin(ADMIN);
        {
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(1000);
            gauge_voting::create_controller(&clk, scenario.ctx());
            ve_staking::create_pool_for_testing(scenario.ctx());
            clk.destroy_for_testing();
        };

        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut controller = scenario.take_shared<GaugeController>();
            gauge_voting::add_gauge(&mut controller, object::id_from_address(@0x1));
            gauge_voting::add_gauge(&mut controller, object::id_from_address(@0x2));
            ts::return_shared(controller);
        };

        // Vote 75% for gauge 0, 25% for gauge 1
        ts::next_tx(&mut scenario, VOTER1);
        {
            let mut controller = scenario.take_shared<GaugeController>();
            let mut pool = scenario.take_shared<VeStakingPool>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(2000);

            let stake_coin1 = coin::mint_for_testing<STAKE_COIN>(75, scenario.ctx());
            let ve_token1 = ve_staking::stake(&mut pool, stake_coin1, 126_230_400_000, &clk, scenario.ctx());
            let record1 = gauge_voting::cast_vote(&mut controller, &pool, &ve_token1, 0, &clk, scenario.ctx());

            let stake_coin2 = coin::mint_for_testing<STAKE_COIN>(25, scenario.ctx());
            let ve_token2 = ve_staking::stake(&mut pool, stake_coin2, 126_230_400_000, &clk, scenario.ctx());
            let record2 = gauge_voting::cast_vote(&mut controller, &pool, &ve_token2, 1, &clk, scenario.ctx());

            // Gauge 0 share = 75/100 = 0.75 WAD
            let share0 = gauge_voting::get_gauge_share(&controller, 0);
            assert!(share0 == 750_000_000_000_000_000); // 0.75 WAD

            let share1 = gauge_voting::get_gauge_share(&controller, 1);
            assert!(share1 == 250_000_000_000_000_000); // 0.25 WAD

            // Emissions: 50000 * 0.75 = 37500 for gauge 0
            let emissions0 = gauge_voting::get_gauge_emissions(&controller, 0);
            assert!(emissions0 == 37_500);

            let emissions1 = gauge_voting::get_gauge_emissions(&controller, 1);
            assert!(emissions1 == 12_500);

            sui::transfer::public_transfer(ve_token1, VOTER1);
            sui::transfer::public_transfer(ve_token2, VOTER1);
            sui::transfer::public_transfer(record1, VOTER1);
            sui::transfer::public_transfer(record2, VOTER1);
            clk.destroy_for_testing();
            ts::return_shared(pool);
            ts::return_shared(controller);
        };
        scenario.end();
    }

    #[test]
    fun test_advance_epoch() {
        let mut scenario = ts::begin(ADMIN);
        {
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(1000);
            gauge_voting::create_controller(&clk, scenario.ctx());
            ve_staking::create_pool_for_testing(scenario.ctx());
            clk.destroy_for_testing();
        };

        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut controller = scenario.take_shared<GaugeController>();
            gauge_voting::add_gauge(&mut controller, object::id_from_address(@0x1));
            ts::return_shared(controller);
        };

        // Cast votes
        ts::next_tx(&mut scenario, VOTER1);
        {
            let mut controller = scenario.take_shared<GaugeController>();
            let mut pool = scenario.take_shared<VeStakingPool>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(2000);
            let stake_coin = coin::mint_for_testing<STAKE_COIN>(100, scenario.ctx());
            let ve_token = ve_staking::stake(&mut pool, stake_coin, 126_230_400_000, &clk, scenario.ctx());
            let record = gauge_voting::cast_vote(&mut controller, &pool, &ve_token, 0, &clk, scenario.ctx());
            sui::transfer::public_transfer(ve_token, VOTER1);
            sui::transfer::public_transfer(record, VOTER1);
            clk.destroy_for_testing();
            ts::return_shared(pool);
            ts::return_shared(controller);
        };

        // Advance epoch after duration
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut controller = scenario.take_shared<GaugeController>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(1000 + EPOCH_DURATION_MS + 1);

            gauge_voting::advance_epoch(&mut controller, &clk);

            assert!(gauge_voting::current_epoch(&controller) == 1);
            // Votes should be reset
            assert!(gauge_voting::total_votes(&controller) == 0);

            clk.destroy_for_testing();
            ts::return_shared(controller);
        };
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = 972)] // EEpochNotEnded
    fun test_advance_epoch_too_early() {
        let mut scenario = ts::begin(ADMIN);
        {
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(1000);
            gauge_voting::create_controller(&clk, scenario.ctx());
            clk.destroy_for_testing();
        };

        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut controller = scenario.take_shared<GaugeController>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(2000); // way before epoch ends

            gauge_voting::advance_epoch(&mut controller, &clk);

            clk.destroy_for_testing();
            ts::return_shared(controller);
        };
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = 965)] // EZeroAmount - ve_staking rejects zero stake
    fun test_zero_vote() {
        let mut scenario = ts::begin(ADMIN);
        {
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(1000);
            gauge_voting::create_controller(&clk, scenario.ctx());
            ve_staking::create_pool_for_testing(scenario.ctx());
            clk.destroy_for_testing();
        };

        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut controller = scenario.take_shared<GaugeController>();
            gauge_voting::add_gauge(&mut controller, object::id_from_address(@0x1));
            ts::return_shared(controller);
        };

        ts::next_tx(&mut scenario, VOTER1);
        {
            let mut controller = scenario.take_shared<GaugeController>();
            let mut pool = scenario.take_shared<VeStakingPool>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(2000);

            // Staking zero will abort in ve_staking with EZeroAmount
            let stake_coin = coin::mint_for_testing<STAKE_COIN>(0, scenario.ctx());
            let ve_token = ve_staking::stake(&mut pool, stake_coin, 126_230_400_000, &clk, scenario.ctx());

            let record = gauge_voting::cast_vote(&mut controller, &pool, &ve_token, 0, &clk, scenario.ctx());

            sui::transfer::public_transfer(ve_token, VOTER1);
            sui::transfer::public_transfer(record, VOTER1);
            clk.destroy_for_testing();
            ts::return_shared(pool);
            ts::return_shared(controller);
        };
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = 970)] // EGaugeNotFound
    fun test_vote_invalid_gauge() {
        let mut scenario = ts::begin(ADMIN);
        {
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(1000);
            gauge_voting::create_controller(&clk, scenario.ctx());
            ve_staking::create_pool_for_testing(scenario.ctx());
            clk.destroy_for_testing();
        };

        ts::next_tx(&mut scenario, VOTER1);
        {
            let mut controller = scenario.take_shared<GaugeController>();
            let mut pool = scenario.take_shared<VeStakingPool>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(2000);

            let stake_coin = coin::mint_for_testing<STAKE_COIN>(100, scenario.ctx());
            let ve_token = ve_staking::stake(&mut pool, stake_coin, 126_230_400_000, &clk, scenario.ctx());

            // No gauges added, index 0 doesn't exist
            let record = gauge_voting::cast_vote(&mut controller, &pool, &ve_token, 0, &clk, scenario.ctx());

            sui::transfer::public_transfer(ve_token, VOTER1);
            sui::transfer::public_transfer(record, VOTER1);
            clk.destroy_for_testing();
            ts::return_shared(pool);
            ts::return_shared(controller);
        };
        scenario.end();
    }

    #[test]
    fun test_multiple_epochs() {
        let mut scenario = ts::begin(ADMIN);
        {
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(1000);
            gauge_voting::create_controller(&clk, scenario.ctx());
            clk.destroy_for_testing();
        };

        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut controller = scenario.take_shared<GaugeController>();
            gauge_voting::add_gauge(&mut controller, object::id_from_address(@0x1));
            ts::return_shared(controller);
        };

        // Advance epoch 1
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut controller = scenario.take_shared<GaugeController>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(1000 + EPOCH_DURATION_MS);
            gauge_voting::advance_epoch(&mut controller, &clk);
            assert!(gauge_voting::current_epoch(&controller) == 1);
            clk.destroy_for_testing();
            ts::return_shared(controller);
        };

        // Advance epoch 2
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut controller = scenario.take_shared<GaugeController>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(1000 + 2 * EPOCH_DURATION_MS);
            gauge_voting::advance_epoch(&mut controller, &clk);
            assert!(gauge_voting::current_epoch(&controller) == 2);
            clk.destroy_for_testing();
            ts::return_shared(controller);
        };
        scenario.end();
    }
}
