#[test_only]
module crux::tranche_tests {
    use sui::test_scenario::{Self as ts};
    use sui::clock;

    use crux::tranche_engine::{Self, TrancheVault, SeniorTranche, JuniorTranche, AdminCap};

    const ADMIN: address = @0xAD;
    const USER1: address = @0xB0B;
    const USER2: address = @0xCAFE;

    const WAD: u128 = 1_000_000_000_000_000_000;

    fun setup(): ts::Scenario {
        let mut scenario = ts::begin(ADMIN);
        {
            tranche_engine::init_for_testing(scenario.ctx());
            let mut clock = clock::create_for_testing(scenario.ctx());
            clock.set_for_testing(1000);
            let _vault_id = tranche_engine::create_tranche_vault(
                100_000_000,                    // maturity far in future
                50_000_000_000_000_000,         // 5% target rate
                4,                               // max 4:1 senior:junior ratio
                &clock,
                scenario.ctx(),
            );
            clock.destroy_for_testing();
        };
        scenario
    }

    #[test]
    fun test_create_tranche_vault() {
        let mut scenario = setup();

        scenario.next_tx(ADMIN);
        {
            let vault = scenario.take_shared<TrancheVault>();
            assert!(tranche_engine::senior_target_rate(&vault) == 50_000_000_000_000_000);
            assert!(tranche_engine::total_deposited(&vault) == 0);
            assert!(tranche_engine::senior_supply(&vault) == 0);
            assert!(tranche_engine::junior_supply(&vault) == 0);
            assert!(!tranche_engine::is_settled(&vault));
            ts::return_shared(vault);
        };
        scenario.end();
    }

    #[test]
    fun test_deposit_senior() {
        let mut scenario = setup();

        scenario.next_tx(USER1);
        {
            let mut vault = scenario.take_shared<TrancheVault>();
            let mut clock = clock::create_for_testing(scenario.ctx());
            clock.set_for_testing(2000);

            // Must deposit junior first to satisfy ratio
            let junior = tranche_engine::deposit_junior(&mut vault, 200, &clock, scenario.ctx());
            let senior = tranche_engine::deposit_senior(&mut vault, 800, &clock, scenario.ctx());

            assert!(tranche_engine::senior_supply(&vault) == 800);
            assert!(tranche_engine::junior_supply(&vault) == 200);
            assert!(tranche_engine::total_deposited(&vault) == 1000);

            sui::transfer::public_transfer(senior, USER1);
            sui::transfer::public_transfer(junior, USER1);
            clock.destroy_for_testing();
            ts::return_shared(vault);
        };
        scenario.end();
    }

    #[test]
    fun test_junior_leverage() {
        let mut scenario = setup();

        scenario.next_tx(USER1);
        {
            let mut vault = scenario.take_shared<TrancheVault>();
            let mut clock = clock::create_for_testing(scenario.ctx());
            clock.set_for_testing(2000);

            let junior = tranche_engine::deposit_junior(&mut vault, 200, &clock, scenario.ctx());
            let senior = tranche_engine::deposit_senior(&mut vault, 800, &clock, scenario.ctx());

            // Leverage = total / junior = 1000/200 = 5.0
            let leverage = tranche_engine::junior_leverage(&vault);
            assert!(leverage == 5 * WAD);

            sui::transfer::public_transfer(senior, USER1);
            sui::transfer::public_transfer(junior, USER1);
            clock.destroy_for_testing();
            ts::return_shared(vault);
        };
        scenario.end();
    }

    #[test]
    fun test_settle_excess_yield() {
        let mut scenario = setup();

        // Deposit
        scenario.next_tx(USER1);
        {
            let mut vault = scenario.take_shared<TrancheVault>();
            let mut clock = clock::create_for_testing(scenario.ctx());
            clock.set_for_testing(2000);

            let junior = tranche_engine::deposit_junior(&mut vault, 200, &clock, scenario.ctx());
            let senior = tranche_engine::deposit_senior(&mut vault, 800, &clock, scenario.ctx());

            sui::transfer::public_transfer(senior, USER1);
            sui::transfer::public_transfer(junior, USER2);
            clock.destroy_for_testing();
            ts::return_shared(vault);
        };

        // Settle with 8% yield = 80 SY total yield
        // Senior target = 5% of 800 = 40 SY
        // Junior gets remainder = 40 SY (20% return on 200)
        scenario.next_tx(ADMIN);
        {
            let admin_cap = scenario.take_from_sender<AdminCap>();
            let mut vault = scenario.take_shared<TrancheVault>();
            let mut clock = clock::create_for_testing(scenario.ctx());
            clock.set_for_testing(100_000_001); // past maturity

            tranche_engine::settle(&admin_cap, &mut vault, 80, &clock);
            assert!(tranche_engine::is_settled(&vault));

            clock.destroy_for_testing();
            scenario.return_to_sender(admin_cap);
            ts::return_shared(vault);
        };

        // Redeem senior
        scenario.next_tx(USER1);
        {
            let vault = scenario.take_shared<TrancheVault>();
            let senior = scenario.take_from_sender<SeniorTranche>();

            let payout = tranche_engine::redeem_senior(&vault, senior);
            // Senior gets 800 + 40 = 840 (1.05 * 800)
            assert!(payout == 840);

            ts::return_shared(vault);
        };

        // Redeem junior
        scenario.next_tx(USER2);
        {
            let vault = scenario.take_shared<TrancheVault>();
            let junior = scenario.take_from_sender<JuniorTranche>();

            let payout = tranche_engine::redeem_junior(&vault, junior);
            // Junior gets 200 + 40 = 240 (1.2 * 200)
            assert!(payout == 240);

            ts::return_shared(vault);
        };
        scenario.end();
    }

    #[test]
    fun test_settle_insufficient_yield() {
        let mut scenario = setup();

        // Deposit
        scenario.next_tx(USER1);
        {
            let mut vault = scenario.take_shared<TrancheVault>();
            let mut clock = clock::create_for_testing(scenario.ctx());
            clock.set_for_testing(2000);

            let junior = tranche_engine::deposit_junior(&mut vault, 200, &clock, scenario.ctx());
            let senior = tranche_engine::deposit_senior(&mut vault, 800, &clock, scenario.ctx());

            sui::transfer::public_transfer(senior, USER1);
            sui::transfer::public_transfer(junior, USER2);
            clock.destroy_for_testing();
            ts::return_shared(vault);
        };

        // Settle with 2% yield = 20 SY
        // Senior target = 40, but only 20 available -> senior gets all 20
        // Junior gets 0 yield (first-loss)
        scenario.next_tx(ADMIN);
        {
            let admin_cap = scenario.take_from_sender<AdminCap>();
            let mut vault = scenario.take_shared<TrancheVault>();
            let mut clock = clock::create_for_testing(scenario.ctx());
            clock.set_for_testing(100_000_001);

            tranche_engine::settle(&admin_cap, &mut vault, 20, &clock);

            clock.destroy_for_testing();
            scenario.return_to_sender(admin_cap);
            ts::return_shared(vault);
        };

        // Redeem senior — gets principal + partial yield (20/800)
        scenario.next_tx(USER1);
        {
            let vault = scenario.take_shared<TrancheVault>();
            let senior = scenario.take_from_sender<SeniorTranche>();

            let payout = tranche_engine::redeem_senior(&vault, senior);
            // Senior gets 800 + 20 = 820
            assert!(payout == 820);

            ts::return_shared(vault);
        };

        // Redeem junior — gets only principal (first-loss)
        scenario.next_tx(USER2);
        {
            let vault = scenario.take_shared<TrancheVault>();
            let junior = scenario.take_from_sender<JuniorTranche>();

            let payout = tranche_engine::redeem_junior(&vault, junior);
            // Junior gets principal only = 200
            assert!(payout == 200);

            ts::return_shared(vault);
        };
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = 1001)] // ETrancheNotExpired
    fun test_settle_before_maturity() {
        let mut scenario = setup();

        scenario.next_tx(ADMIN);
        {
            let admin_cap = scenario.take_from_sender<AdminCap>();
            let mut vault = scenario.take_shared<TrancheVault>();
            let mut clock = clock::create_for_testing(scenario.ctx());
            clock.set_for_testing(2000); // before maturity

            tranche_engine::settle(&admin_cap, &mut vault, 80, &clock);

            clock.destroy_for_testing();
            scenario.return_to_sender(admin_cap);
            ts::return_shared(vault);
        };
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = 1003)] // ENotSettled
    fun test_redeem_before_settlement() {
        let mut scenario = setup();

        scenario.next_tx(USER1);
        {
            let mut vault = scenario.take_shared<TrancheVault>();
            let mut clock = clock::create_for_testing(scenario.ctx());
            clock.set_for_testing(2000);

            // Deposit junior first to satisfy leverage ratio
            let junior = tranche_engine::deposit_junior(&mut vault, 200, &clock, scenario.ctx());
            let senior = tranche_engine::deposit_senior(&mut vault, 800, &clock, scenario.ctx());
            clock.destroy_for_testing();

            // Try to redeem before settlement
            let _payout = tranche_engine::redeem_senior(&vault, senior);

            sui::transfer::public_transfer(junior, USER1);
            ts::return_shared(vault);
        };
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = 1004)] // EZeroDeposit
    fun test_zero_deposit() {
        let mut scenario = setup();

        scenario.next_tx(USER1);
        {
            let mut vault = scenario.take_shared<TrancheVault>();
            let mut clock = clock::create_for_testing(scenario.ctx());
            clock.set_for_testing(2000);

            let senior = tranche_engine::deposit_senior(&mut vault, 0, &clock, scenario.ctx());

            sui::transfer::public_transfer(senior, USER1);
            clock.destroy_for_testing();
            ts::return_shared(vault);
        };
        scenario.end();
    }
}
