#[test_only]
module crux::permissionless_market_tests {
    use sui::test_scenario::{Self as ts};
    use sui::clock;
    use sui::coin;

    use crux::standardized_yield::{Self, AdminCap, SYVault};
    use crux::permissionless_market::{Self, MarketRegistry};

    public struct MKT_COIN has drop {}

    const ADMIN: address = @0xAD;
    const CREATOR: address = @0xB0B;

    const ONE_MONTH_MS: u64 = 2_629_800_000;
    const ONE_YEAR_MS: u64 = 31_557_600_000;

    fun setup(): ts::Scenario {
        let mut scenario = ts::begin(ADMIN);

        // Init SY
        { standardized_yield::init_for_testing(scenario.ctx()); };

        // Create SY vault
        ts::next_tx(&mut scenario, ADMIN);
        {
            let admin_cap = scenario.take_from_sender<AdminCap>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(1000);
            standardized_yield::create_vault<MKT_COIN>(&admin_cap, &clk, scenario.ctx());
            scenario.return_to_sender(admin_cap);
            clk.destroy_for_testing();
        };

        // Create market registry
        ts::next_tx(&mut scenario, ADMIN);
        {
            permissionless_market::create_registry(scenario.ctx());
        };

        scenario
    }

    #[test]
    fun test_create_registry() {
        let mut scenario = setup();

        ts::next_tx(&mut scenario, ADMIN);
        {
            let registry = scenario.take_shared<MarketRegistry>();
            assert!(permissionless_market::market_count(&registry) == 0);
            ts::return_shared(registry);
        };
        scenario.end();
    }

    #[test]
    fun test_create_market_permissionless() {
        let mut scenario = setup();

        ts::next_tx(&mut scenario, CREATOR);
        {
            let mut registry = scenario.take_shared<MarketRegistry>();
            let mut vault = scenario.take_shared<SYVault<MKT_COIN>>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(1000);

            // Deposit to get SY for seeding
            let deposit = coin::mint_for_testing<MKT_COIN>(500, scenario.ctx());
            let sy = standardized_yield::deposit(&mut vault, deposit, scenario.ctx());

            let maturity = 1000 + ONE_YEAR_MS;
            let market_id = permissionless_market::create_market(
                &mut registry, &vault, sy, maturity, &clk, scenario.ctx(),
            );
            let _ = market_id;

            assert!(permissionless_market::market_count(&registry) == 1);

            let vault_id = standardized_yield::vault_id(&vault);
            assert!(permissionless_market::market_exists(&registry, vault_id, maturity));

            clk.destroy_for_testing();
            ts::return_shared(vault);
            ts::return_shared(registry);
        };
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = 1204)] // EDuplicateMarket
    fun test_duplicate_market() {
        let mut scenario = setup();

        ts::next_tx(&mut scenario, CREATOR);
        {
            let mut registry = scenario.take_shared<MarketRegistry>();
            let mut vault = scenario.take_shared<SYVault<MKT_COIN>>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(1000);

            let deposit1 = coin::mint_for_testing<MKT_COIN>(200, scenario.ctx());
            let sy1 = standardized_yield::deposit(&mut vault, deposit1, scenario.ctx());
            let deposit2 = coin::mint_for_testing<MKT_COIN>(200, scenario.ctx());
            let sy2 = standardized_yield::deposit(&mut vault, deposit2, scenario.ctx());

            let maturity = 1000 + ONE_YEAR_MS;

            // First creation succeeds
            permissionless_market::create_market(
                &mut registry, &vault, sy1, maturity, &clk, scenario.ctx(),
            );

            // Duplicate — should fail
            permissionless_market::create_market(
                &mut registry, &vault, sy2, maturity, &clk, scenario.ctx(),
            );

            clk.destroy_for_testing();
            ts::return_shared(vault);
            ts::return_shared(registry);
        };
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = 1202)] // EMaturityTooSoon
    fun test_maturity_too_soon() {
        let mut scenario = setup();

        ts::next_tx(&mut scenario, CREATOR);
        {
            let mut registry = scenario.take_shared<MarketRegistry>();
            let mut vault = scenario.take_shared<SYVault<MKT_COIN>>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(1000);

            let deposit = coin::mint_for_testing<MKT_COIN>(200, scenario.ctx());
            let sy = standardized_yield::deposit(&mut vault, deposit, scenario.ctx());

            // Maturity only 1 day away (< 7 day minimum)
            let maturity = 1000 + 86_400_000;
            permissionless_market::create_market(
                &mut registry, &vault, sy, maturity, &clk, scenario.ctx(),
            );

            clk.destroy_for_testing();
            ts::return_shared(vault);
            ts::return_shared(registry);
        };
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = 1201)] // EInsufficientLiquidity
    fun test_insufficient_initial_liquidity() {
        let mut scenario = setup();

        ts::next_tx(&mut scenario, CREATOR);
        {
            let mut registry = scenario.take_shared<MarketRegistry>();
            let mut vault = scenario.take_shared<SYVault<MKT_COIN>>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(1000);

            let deposit = coin::mint_for_testing<MKT_COIN>(50, scenario.ctx());
            let sy = standardized_yield::deposit(&mut vault, deposit, scenario.ctx());

            // Only 50 SY, need at least 100
            let maturity = 1000 + ONE_YEAR_MS;
            permissionless_market::create_market(
                &mut registry, &vault, sy, maturity, &clk, scenario.ctx(),
            );

            clk.destroy_for_testing();
            ts::return_shared(vault);
            ts::return_shared(registry);
        };
        scenario.end();
    }
}
