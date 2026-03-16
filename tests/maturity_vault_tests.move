#[test_only]
module crux::maturity_vault_tests {
    use sui::test_scenario::{Self as ts};
    use sui::clock;

    use crux::maturity_vault::{Self, MaturityAdminCap, MaturityRegistry};

    const ADMIN: address = @0xAD;

    fun setup(): ts::Scenario {
        let mut scenario = ts::begin(ADMIN);
        {
            maturity_vault::init_for_testing(scenario.ctx());
        };
        scenario
    }

    #[test]
    fun test_create_standard_maturities() {
        let mut scenario = setup();

        ts::next_tx(&mut scenario, ADMIN);
        {
            let admin_cap = scenario.take_from_sender<MaturityAdminCap>();
            let mut registry = scenario.take_shared<MaturityRegistry>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(1000);

            let market_id = object::id_from_address(@0x1);
            maturity_vault::create_standard_maturities(
                &admin_cap, &mut registry, market_id, &clk,
            );

            assert!(maturity_vault::active_count(&registry) == 4);

            scenario.return_to_sender(admin_cap);
            clk.destroy_for_testing();
            ts::return_shared(registry);
        };
        scenario.end();
    }

    #[test]
    fun test_create_custom_maturity() {
        let mut scenario = setup();

        ts::next_tx(&mut scenario, ADMIN);
        {
            let admin_cap = scenario.take_from_sender<MaturityAdminCap>();
            let mut registry = scenario.take_shared<MaturityRegistry>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(1000);

            let market_id = object::id_from_address(@0x1);
            maturity_vault::create_custom_maturity(
                &admin_cap, &mut registry, 50_000_000, 2, market_id, &clk,
            );

            assert!(maturity_vault::active_count(&registry) == 1);

            scenario.return_to_sender(admin_cap);
            clk.destroy_for_testing();
            ts::return_shared(registry);
        };
        scenario.end();
    }

    #[test]
    fun test_mark_settled() {
        let mut scenario = setup();

        ts::next_tx(&mut scenario, ADMIN);
        {
            let admin_cap = scenario.take_from_sender<MaturityAdminCap>();
            let mut registry = scenario.take_shared<MaturityRegistry>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(1000);

            let market_id = object::id_from_address(@0x1);
            let maturity_ms = 50_000_000u64;
            maturity_vault::create_custom_maturity(
                &admin_cap, &mut registry, maturity_ms, 2, market_id, &clk,
            );
            assert!(maturity_vault::active_count(&registry) == 1);

            // Move past maturity
            clk.set_for_testing(50_000_001);
            maturity_vault::mark_settled(&mut registry, maturity_ms, &clk);

            assert!(maturity_vault::active_count(&registry) == 0);

            scenario.return_to_sender(admin_cap);
            clk.destroy_for_testing();
            ts::return_shared(registry);
        };
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = 803)] // ENotExpired
    fun test_settle_before_expiry() {
        let mut scenario = setup();

        ts::next_tx(&mut scenario, ADMIN);
        {
            let admin_cap = scenario.take_from_sender<MaturityAdminCap>();
            let mut registry = scenario.take_shared<MaturityRegistry>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(1000);

            let market_id = object::id_from_address(@0x1);
            maturity_vault::create_custom_maturity(
                &admin_cap, &mut registry, 50_000_000, 2, market_id, &clk,
            );

            // Try to settle before maturity
            clk.set_for_testing(2000);
            maturity_vault::mark_settled(&mut registry, 50_000_000, &clk);

            scenario.return_to_sender(admin_cap);
            clk.destroy_for_testing();
            ts::return_shared(registry);
        };
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = 800)] // EMaturityInPast
    fun test_create_maturity_in_past() {
        let mut scenario = setup();

        ts::next_tx(&mut scenario, ADMIN);
        {
            let admin_cap = scenario.take_from_sender<MaturityAdminCap>();
            let mut registry = scenario.take_shared<MaturityRegistry>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(100_000);

            let market_id = object::id_from_address(@0x1);
            // Maturity before current time
            maturity_vault::create_custom_maturity(
                &admin_cap, &mut registry, 50_000, 1, market_id, &clk,
            );

            scenario.return_to_sender(admin_cap);
            clk.destroy_for_testing();
            ts::return_shared(registry);
        };
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = 801)] // EDuplicateMaturity
    fun test_duplicate_maturity() {
        let mut scenario = setup();

        ts::next_tx(&mut scenario, ADMIN);
        {
            let admin_cap = scenario.take_from_sender<MaturityAdminCap>();
            let mut registry = scenario.take_shared<MaturityRegistry>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(1000);

            let market_id = object::id_from_address(@0x1);
            maturity_vault::create_custom_maturity(
                &admin_cap, &mut registry, 50_000_000, 2, market_id, &clk,
            );
            // Same maturity again
            maturity_vault::create_custom_maturity(
                &admin_cap, &mut registry, 50_000_000, 2, market_id, &clk,
            );

            scenario.return_to_sender(admin_cap);
            clk.destroy_for_testing();
            ts::return_shared(registry);
        };
        scenario.end();
    }

    #[test]
    fun test_expiring_within() {
        let mut scenario = setup();

        ts::next_tx(&mut scenario, ADMIN);
        {
            let admin_cap = scenario.take_from_sender<MaturityAdminCap>();
            let mut registry = scenario.take_shared<MaturityRegistry>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(1000);

            let market_id = object::id_from_address(@0x1);
            maturity_vault::create_custom_maturity(
                &admin_cap, &mut registry, 10_000, 1, market_id, &clk,
            );
            maturity_vault::create_custom_maturity(
                &admin_cap, &mut registry, 50_000, 2, market_id, &clk,
            );
            maturity_vault::create_custom_maturity(
                &admin_cap, &mut registry, 100_000, 3, market_id, &clk,
            );

            // At t=1000, look within 20_000ms window
            let expiring = maturity_vault::expiring_within(&registry, 20_000, &clk);
            assert!(expiring.length() == 1); // only 10_000 is within [1000, 21_000]

            // At t=1000, look within 100_000ms window
            let expiring_all = maturity_vault::expiring_within(&registry, 100_000, &clk);
            assert!(expiring_all.length() == 3); // all 3 are within

            scenario.return_to_sender(admin_cap);
            clk.destroy_for_testing();
            ts::return_shared(registry);
        };
        scenario.end();
    }

    #[test]
    fun test_standard_durations() {
        let durations = maturity_vault::standard_durations();
        assert!(durations.length() == 4);
    }
}
