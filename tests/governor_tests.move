#[test_only]
module crux::governor_tests {
    use sui::test_scenario::{Self as ts};
    use sui::clock;
    use sui::coin;

    use crux::governor::{Self, GovernorState, GovernorAdminCap};
    use crux::ve_staking::{Self, VeStakingPool, VeToken};

    public struct STAKE_COIN has drop {}

    const ADMIN: address = @0xAD;
    const VOTER1: address = @0xB0B;
    const VOTER2: address = @0xCAFE;

    const VOTING_PERIOD_MS: u64 = 259_200_000;   // 3 days
    const TIMELOCK_MS: u64 = 172_800_000;         // 2 days
    const QUORUM_VOTES: u64 = 100_000;

    fun setup(): ts::Scenario {
        let mut scenario = ts::begin(ADMIN);
        {
            governor::init_for_testing(scenario.ctx());
            ve_staking::create_pool_for_testing(scenario.ctx());
        };
        scenario
    }

    #[test]
    fun test_create_proposal() {
        let mut scenario = setup();

        scenario.next_tx(ADMIN);
        {
            let mut state = scenario.take_shared<GovernorState>();
            let mut pool = scenario.take_shared<VeStakingPool>();
            let mut clock = clock::create_for_testing(scenario.ctx());
            clock.set_for_testing(1000);

            let stake_coin = coin::mint_for_testing<STAKE_COIN>(4000, scenario.ctx());
            let ve_token = ve_staking::stake(&mut pool, stake_coin, 31_557_600_000, &clock, scenario.ctx());

            let proposal_id = governor::create_proposal(
                &mut state,
                &pool,
                &ve_token,
                b"Test Proposal",
                &clock,
                scenario.ctx(),
            );

            assert!(proposal_id == 0);
            assert!(governor::proposal_count(&state) == 1);

            let proposal_state = governor::proposal_state(&state, 0);
            assert!(proposal_state == 0); // STATE_ACTIVE

            sui::transfer::public_transfer(ve_token, ADMIN);
            clock.destroy_for_testing();
            ts::return_shared(pool);
            ts::return_shared(state);
        };
        scenario.end();
    }

    #[test]
    fun test_cast_vote() {
        let mut scenario = setup();

        // Create proposal
        scenario.next_tx(ADMIN);
        {
            let mut state = scenario.take_shared<GovernorState>();
            let mut pool = scenario.take_shared<VeStakingPool>();
            let mut clock = clock::create_for_testing(scenario.ctx());
            clock.set_for_testing(1000);
            let stake_coin = coin::mint_for_testing<STAKE_COIN>(4000, scenario.ctx());
            let ve_token = ve_staking::stake(&mut pool, stake_coin, 31_557_600_000, &clock, scenario.ctx());
            governor::create_proposal(&mut state, &pool, &ve_token, b"Vote Test", &clock, scenario.ctx());
            sui::transfer::public_transfer(ve_token, ADMIN);
            clock.destroy_for_testing();
            ts::return_shared(pool);
            ts::return_shared(state);
        };

        // Vote
        scenario.next_tx(VOTER1);
        {
            let mut state = scenario.take_shared<GovernorState>();
            let mut pool = scenario.take_shared<VeStakingPool>();
            let mut clock = clock::create_for_testing(scenario.ctx());
            clock.set_for_testing(2000);

            let stake_coin = coin::mint_for_testing<STAKE_COIN>(60_000, scenario.ctx());
            let ve_token = ve_staking::stake(&mut pool, stake_coin, 31_557_600_000, &clock, scenario.ctx());

            governor::cast_vote(
                &mut state,
                &pool,
                &ve_token,
                0,
                true,
                &clock,
                scenario.ctx(),
            );

            sui::transfer::public_transfer(ve_token, VOTER1);
            clock.destroy_for_testing();
            ts::return_shared(pool);
            ts::return_shared(state);
        };

        // Another vote
        scenario.next_tx(VOTER2);
        {
            let mut state = scenario.take_shared<GovernorState>();
            let mut pool = scenario.take_shared<VeStakingPool>();
            let mut clock = clock::create_for_testing(scenario.ctx());
            clock.set_for_testing(3000);

            let stake_coin = coin::mint_for_testing<STAKE_COIN>(50_000, scenario.ctx());
            let ve_token = ve_staking::stake(&mut pool, stake_coin, 31_557_600_000, &clock, scenario.ctx());

            governor::cast_vote(
                &mut state,
                &pool,
                &ve_token,
                0,
                true,
                &clock,
                scenario.ctx(),
            );

            sui::transfer::public_transfer(ve_token, VOTER2);
            clock.destroy_for_testing();
            ts::return_shared(pool);
            ts::return_shared(state);
        };
        scenario.end();
    }

    #[test]
    fun test_full_governance_lifecycle() {
        let mut scenario = setup();

        let start_ms: u64 = 1000;

        // Create proposal
        scenario.next_tx(ADMIN);
        {
            let mut state = scenario.take_shared<GovernorState>();
            let mut pool = scenario.take_shared<VeStakingPool>();
            let mut clock = clock::create_for_testing(scenario.ctx());
            clock.set_for_testing(start_ms);
            let stake_coin = coin::mint_for_testing<STAKE_COIN>(4000, scenario.ctx());
            let ve_token = ve_staking::stake(&mut pool, stake_coin, 31_557_600_000, &clock, scenario.ctx());
            governor::create_proposal(&mut state, &pool, &ve_token, b"Lifecycle Test", &clock, scenario.ctx());
            sui::transfer::public_transfer(ve_token, ADMIN);
            clock.destroy_for_testing();
            ts::return_shared(pool);
            ts::return_shared(state);
        };

        // Vote to exceed quorum
        scenario.next_tx(VOTER1);
        {
            let mut state = scenario.take_shared<GovernorState>();
            let mut pool = scenario.take_shared<VeStakingPool>();
            let mut clock = clock::create_for_testing(scenario.ctx());
            clock.set_for_testing(start_ms + 1000);
            let stake_coin = coin::mint_for_testing<STAKE_COIN>(280_000, scenario.ctx());
            let ve_token = ve_staking::stake(&mut pool, stake_coin, 31_557_600_000, &clock, scenario.ctx());
            governor::cast_vote(&mut state, &pool, &ve_token, 0, true, &clock, scenario.ctx());
            sui::transfer::public_transfer(ve_token, VOTER1);
            clock.destroy_for_testing();
            ts::return_shared(pool);
            ts::return_shared(state);
        };

        scenario.next_tx(VOTER2);
        {
            let mut state = scenario.take_shared<GovernorState>();
            let mut pool = scenario.take_shared<VeStakingPool>();
            let mut clock = clock::create_for_testing(scenario.ctx());
            clock.set_for_testing(start_ms + 2000);
            let stake_coin = coin::mint_for_testing<STAKE_COIN>(160_000, scenario.ctx());
            let ve_token = ve_staking::stake(&mut pool, stake_coin, 31_557_600_000, &clock, scenario.ctx());
            governor::cast_vote(&mut state, &pool, &ve_token, 0, true, &clock, scenario.ctx());
            sui::transfer::public_transfer(ve_token, VOTER2);
            clock.destroy_for_testing();
            ts::return_shared(pool);
            ts::return_shared(state);
        };

        // Queue proposal after voting period
        scenario.next_tx(ADMIN);
        {
            let mut state = scenario.take_shared<GovernorState>();
            let mut clock = clock::create_for_testing(scenario.ctx());
            clock.set_for_testing(start_ms + VOTING_PERIOD_MS + 1);
            governor::queue_proposal(&mut state, 0, &clock);

            let proposal_state = governor::proposal_state(&state, 0);
            assert!(proposal_state == 3); // STATE_QUEUED

            clock.destroy_for_testing();
            ts::return_shared(state);
        };

        // Execute proposal after timelock
        scenario.next_tx(ADMIN);
        {
            let mut state = scenario.take_shared<GovernorState>();
            let mut clock = clock::create_for_testing(scenario.ctx());
            clock.set_for_testing(start_ms + VOTING_PERIOD_MS + TIMELOCK_MS + 1);
            governor::execute_proposal(&mut state, 0, &clock);

            let proposal_state = governor::proposal_state(&state, 0);
            assert!(proposal_state == 4); // STATE_EXECUTED

            clock.destroy_for_testing();
            ts::return_shared(state);
        };
        scenario.end();
    }

    #[test]
    fun test_cancel_proposal() {
        let mut scenario = setup();

        // Create proposal
        scenario.next_tx(ADMIN);
        {
            let mut state = scenario.take_shared<GovernorState>();
            let mut pool = scenario.take_shared<VeStakingPool>();
            let mut clock = clock::create_for_testing(scenario.ctx());
            clock.set_for_testing(1000);
            let stake_coin = coin::mint_for_testing<STAKE_COIN>(4000, scenario.ctx());
            let ve_token = ve_staking::stake(&mut pool, stake_coin, 31_557_600_000, &clock, scenario.ctx());
            governor::create_proposal(&mut state, &pool, &ve_token, b"Cancel Test", &clock, scenario.ctx());
            sui::transfer::public_transfer(ve_token, ADMIN);
            clock.destroy_for_testing();
            ts::return_shared(pool);
            ts::return_shared(state);
        };

        // Cancel
        scenario.next_tx(ADMIN);
        {
            let admin_cap = scenario.take_from_sender<GovernorAdminCap>();
            let mut state = scenario.take_shared<GovernorState>();

            governor::cancel_proposal(&admin_cap, &mut state, 0);

            let proposal_state = governor::proposal_state(&state, 0);
            assert!(proposal_state == 5); // STATE_CANCELLED

            scenario.return_to_sender(admin_cap);
            ts::return_shared(state);
        };
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = 953)] // EAlreadyVoted
    fun test_double_vote() {
        let mut scenario = setup();

        // Create proposal
        scenario.next_tx(ADMIN);
        {
            let mut state = scenario.take_shared<GovernorState>();
            let mut pool = scenario.take_shared<VeStakingPool>();
            let mut clock = clock::create_for_testing(scenario.ctx());
            clock.set_for_testing(1000);
            let stake_coin = coin::mint_for_testing<STAKE_COIN>(4000, scenario.ctx());
            let ve_token = ve_staking::stake(&mut pool, stake_coin, 31_557_600_000, &clock, scenario.ctx());
            governor::create_proposal(&mut state, &pool, &ve_token, b"Double Vote", &clock, scenario.ctx());
            sui::transfer::public_transfer(ve_token, ADMIN);
            clock.destroy_for_testing();
            ts::return_shared(pool);
            ts::return_shared(state);
        };

        // Vote once
        scenario.next_tx(VOTER1);
        {
            let mut state = scenario.take_shared<GovernorState>();
            let mut pool = scenario.take_shared<VeStakingPool>();
            let mut clock = clock::create_for_testing(scenario.ctx());
            clock.set_for_testing(2000);
            let stake_coin = coin::mint_for_testing<STAKE_COIN>(50_000, scenario.ctx());
            let ve_token = ve_staking::stake(&mut pool, stake_coin, 31_557_600_000, &clock, scenario.ctx());
            governor::cast_vote(&mut state, &pool, &ve_token, 0, true, &clock, scenario.ctx());
            sui::transfer::public_transfer(ve_token, VOTER1);
            clock.destroy_for_testing();
            ts::return_shared(pool);
            ts::return_shared(state);
        };

        // Vote again — should fail
        scenario.next_tx(VOTER1);
        {
            let mut state = scenario.take_shared<GovernorState>();
            let mut pool = scenario.take_shared<VeStakingPool>();
            let ve_token = scenario.take_from_sender<VeToken>();
            let mut clock = clock::create_for_testing(scenario.ctx());
            clock.set_for_testing(3000);
            governor::cast_vote(&mut state, &pool, &ve_token, 0, true, &clock, scenario.ctx());
            sui::transfer::public_transfer(ve_token, VOTER1);
            clock.destroy_for_testing();
            ts::return_shared(pool);
            ts::return_shared(state);
        };
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = 956)] // EQuorumNotReached
    fun test_queue_without_quorum() {
        let mut scenario = setup();

        // Create proposal
        scenario.next_tx(ADMIN);
        {
            let mut state = scenario.take_shared<GovernorState>();
            let mut pool = scenario.take_shared<VeStakingPool>();
            let mut clock = clock::create_for_testing(scenario.ctx());
            clock.set_for_testing(1000);
            let stake_coin = coin::mint_for_testing<STAKE_COIN>(4000, scenario.ctx());
            let ve_token = ve_staking::stake(&mut pool, stake_coin, 31_557_600_000, &clock, scenario.ctx());
            governor::create_proposal(&mut state, &pool, &ve_token, b"No Quorum", &clock, scenario.ctx());
            sui::transfer::public_transfer(ve_token, ADMIN);
            clock.destroy_for_testing();
            ts::return_shared(pool);
            ts::return_shared(state);
        };

        // Vote below quorum
        scenario.next_tx(VOTER1);
        {
            let mut state = scenario.take_shared<GovernorState>();
            let mut pool = scenario.take_shared<VeStakingPool>();
            let mut clock = clock::create_for_testing(scenario.ctx());
            clock.set_for_testing(2000);
            let stake_coin = coin::mint_for_testing<STAKE_COIN>(50_000, scenario.ctx());
            let ve_token = ve_staking::stake(&mut pool, stake_coin, 31_557_600_000, &clock, scenario.ctx());
            governor::cast_vote(&mut state, &pool, &ve_token, 0, true, &clock, scenario.ctx());
            sui::transfer::public_transfer(ve_token, VOTER1);
            clock.destroy_for_testing();
            ts::return_shared(pool);
            ts::return_shared(state);
        };

        // Try to queue — should fail (only 50k votes, need 100k)
        scenario.next_tx(ADMIN);
        {
            let mut state = scenario.take_shared<GovernorState>();
            let mut clock = clock::create_for_testing(scenario.ctx());
            clock.set_for_testing(1000 + VOTING_PERIOD_MS + 1);
            governor::queue_proposal(&mut state, 0, &clock);
            clock.destroy_for_testing();
            ts::return_shared(state);
        };
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = 957)] // EProposalDefeated
    fun test_queue_defeated_proposal() {
        let mut scenario = setup();

        // Create proposal
        scenario.next_tx(ADMIN);
        {
            let mut state = scenario.take_shared<GovernorState>();
            let mut pool = scenario.take_shared<VeStakingPool>();
            let mut clock = clock::create_for_testing(scenario.ctx());
            clock.set_for_testing(1000);
            let stake_coin = coin::mint_for_testing<STAKE_COIN>(4000, scenario.ctx());
            let ve_token = ve_staking::stake(&mut pool, stake_coin, 31_557_600_000, &clock, scenario.ctx());
            governor::create_proposal(&mut state, &pool, &ve_token, b"Defeated", &clock, scenario.ctx());
            sui::transfer::public_transfer(ve_token, ADMIN);
            clock.destroy_for_testing();
            ts::return_shared(pool);
            ts::return_shared(state);
        };

        // Vote against with quorum
        scenario.next_tx(VOTER1);
        {
            let mut state = scenario.take_shared<GovernorState>();
            let mut pool = scenario.take_shared<VeStakingPool>();
            let mut clock = clock::create_for_testing(scenario.ctx());
            clock.set_for_testing(2000);
            let stake_coin = coin::mint_for_testing<STAKE_COIN>(240_000, scenario.ctx());
            let ve_token = ve_staking::stake(&mut pool, stake_coin, 31_557_600_000, &clock, scenario.ctx());
            governor::cast_vote(&mut state, &pool, &ve_token, 0, false, &clock, scenario.ctx());
            sui::transfer::public_transfer(ve_token, VOTER1);
            clock.destroy_for_testing();
            ts::return_shared(pool);
            ts::return_shared(state);
        };

        scenario.next_tx(VOTER2);
        {
            let mut state = scenario.take_shared<GovernorState>();
            let mut pool = scenario.take_shared<VeStakingPool>();
            let mut clock = clock::create_for_testing(scenario.ctx());
            clock.set_for_testing(3000);
            let stake_coin = coin::mint_for_testing<STAKE_COIN>(200_000, scenario.ctx());
            let ve_token = ve_staking::stake(&mut pool, stake_coin, 31_557_600_000, &clock, scenario.ctx());
            governor::cast_vote(&mut state, &pool, &ve_token, 0, true, &clock, scenario.ctx());
            sui::transfer::public_transfer(ve_token, VOTER2);
            clock.destroy_for_testing();
            ts::return_shared(pool);
            ts::return_shared(state);
        };

        // Try to queue — should fail (50k for, 60k against)
        scenario.next_tx(ADMIN);
        {
            let mut state = scenario.take_shared<GovernorState>();
            let mut clock = clock::create_for_testing(scenario.ctx());
            clock.set_for_testing(1000 + VOTING_PERIOD_MS + 1);
            governor::queue_proposal(&mut state, 0, &clock);
            clock.destroy_for_testing();
            ts::return_shared(state);
        };
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = 952)] // EProposalNotReady
    fun test_execute_before_timelock() {
        let mut scenario = setup();
        let start_ms: u64 = 1000;

        // Create, vote, queue
        scenario.next_tx(ADMIN);
        {
            let mut state = scenario.take_shared<GovernorState>();
            let mut pool = scenario.take_shared<VeStakingPool>();
            let mut clock = clock::create_for_testing(scenario.ctx());
            clock.set_for_testing(start_ms);
            let stake_coin = coin::mint_for_testing<STAKE_COIN>(4000, scenario.ctx());
            let ve_token = ve_staking::stake(&mut pool, stake_coin, 31_557_600_000, &clock, scenario.ctx());
            governor::create_proposal(&mut state, &pool, &ve_token, b"Early Execute", &clock, scenario.ctx());
            sui::transfer::public_transfer(ve_token, ADMIN);
            clock.destroy_for_testing();
            ts::return_shared(pool);
            ts::return_shared(state);
        };

        scenario.next_tx(VOTER1);
        {
            let mut state = scenario.take_shared<GovernorState>();
            let mut pool = scenario.take_shared<VeStakingPool>();
            let mut clock = clock::create_for_testing(scenario.ctx());
            clock.set_for_testing(start_ms + 1000);
            let stake_coin = coin::mint_for_testing<STAKE_COIN>((QUORUM_VOTES + 1) * 4, scenario.ctx());
            let ve_token = ve_staking::stake(&mut pool, stake_coin, 31_557_600_000, &clock, scenario.ctx());
            governor::cast_vote(&mut state, &pool, &ve_token, 0, true, &clock, scenario.ctx());
            sui::transfer::public_transfer(ve_token, VOTER1);
            clock.destroy_for_testing();
            ts::return_shared(pool);
            ts::return_shared(state);
        };

        scenario.next_tx(ADMIN);
        {
            let mut state = scenario.take_shared<GovernorState>();
            let mut clock = clock::create_for_testing(scenario.ctx());
            clock.set_for_testing(start_ms + VOTING_PERIOD_MS + 1);
            governor::queue_proposal(&mut state, 0, &clock);
            clock.destroy_for_testing();
            ts::return_shared(state);
        };

        // Try to execute before timelock — should fail
        scenario.next_tx(ADMIN);
        {
            let mut state = scenario.take_shared<GovernorState>();
            let mut clock = clock::create_for_testing(scenario.ctx());
            clock.set_for_testing(start_ms + VOTING_PERIOD_MS + 100); // only 100ms after queue
            governor::execute_proposal(&mut state, 0, &clock);
            clock.destroy_for_testing();
            ts::return_shared(state);
        };
        scenario.end();
    }
}
