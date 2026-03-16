#[test_only]
module crux::pt_collateral_tests {
    use sui::test_scenario::{Self as ts};
    use sui::clock;
    use sui::coin;

    use crux::standardized_yield::{Self, AdminCap, SYVault};
    use crux::yield_tokenizer::{Self, YieldMarketConfig};
    use crux::pt_collateral::{Self, CollateralManager, CollateralReceipt};

    public struct COLL_COIN has drop {}

    const ADMIN: address = @0xAD;
    const USER: address = @0xB0B;
    const LIQUIDATOR: address = @0xCAFE;

    const MATURITY_MS: u64 = 100_000_000;

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
            standardized_yield::create_vault<COLL_COIN>(&admin_cap, &clk, scenario.ctx());
            scenario.return_to_sender(admin_cap);
            clk.destroy_for_testing();
        };

        // Create yield market
        ts::next_tx(&mut scenario, ADMIN);
        {
            let vault = scenario.take_shared<SYVault<COLL_COIN>>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(1000);
            yield_tokenizer::create_market<COLL_COIN>(&vault, MATURITY_MS, &clk, scenario.ctx());
            clk.destroy_for_testing();
            ts::return_shared(vault);
        };

        // Create collateral manager
        ts::next_tx(&mut scenario, ADMIN);
        {
            let config = scenario.take_shared<YieldMarketConfig<COLL_COIN>>();
            pt_collateral::create_manager(&config, scenario.ctx());
            ts::return_shared(config);
        };

        scenario
    }

    #[test]
    fun test_deposit_collateral() {
        let mut scenario = setup();

        // Mint PT for user
        ts::next_tx(&mut scenario, USER);
        {
            let mut vault = scenario.take_shared<SYVault<COLL_COIN>>();
            let deposit = coin::mint_for_testing<COLL_COIN>(1000, scenario.ctx());
            let sy = standardized_yield::deposit(&mut vault, deposit, scenario.ctx());
            ts::return_shared(vault);

            let mut config = scenario.take_shared<YieldMarketConfig<COLL_COIN>>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(2000);
            let (pt, yt) = yield_tokenizer::mint_py(&mut config, sy, &clk, scenario.ctx());
            sui::transfer::public_transfer(yt, USER);
            clk.destroy_for_testing();
            ts::return_shared(config);

            // Deposit PT as collateral
            let mut manager = scenario.take_shared<CollateralManager<COLL_COIN>>();
            let mut clk2 = clock::create_for_testing(scenario.ctx());
            clk2.set_for_testing(2000);
            let receipt = pt_collateral::deposit_collateral(&mut manager, pt, &clk2, scenario.ctx());

            assert!(pt_collateral::total_pt_locked(&manager) == 1000);
            assert!(pt_collateral::position_count(&manager) == 1);

            sui::transfer::public_transfer(receipt, USER);
            clk2.destroy_for_testing();
            ts::return_shared(manager);
        };
        scenario.end();
    }

    #[test]
    fun test_borrow_and_repay() {
        let mut scenario = setup();

        // Mint PT + deposit as collateral
        ts::next_tx(&mut scenario, USER);
        {
            let mut vault = scenario.take_shared<SYVault<COLL_COIN>>();
            let deposit = coin::mint_for_testing<COLL_COIN>(1000, scenario.ctx());
            let sy = standardized_yield::deposit(&mut vault, deposit, scenario.ctx());
            ts::return_shared(vault);

            let mut config = scenario.take_shared<YieldMarketConfig<COLL_COIN>>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(2000);
            let (pt, yt) = yield_tokenizer::mint_py(&mut config, sy, &clk, scenario.ctx());
            sui::transfer::public_transfer(yt, USER);
            clk.destroy_for_testing();
            ts::return_shared(config);

            let mut manager = scenario.take_shared<CollateralManager<COLL_COIN>>();
            let mut clk2 = clock::create_for_testing(scenario.ctx());
            clk2.set_for_testing(2000);
            let receipt = pt_collateral::deposit_collateral(&mut manager, pt, &clk2, scenario.ctx());
            sui::transfer::public_transfer(receipt, USER);
            clk2.destroy_for_testing();
            ts::return_shared(manager);
        };

        // Borrow against collateral
        ts::next_tx(&mut scenario, USER);
        {
            let mut manager = scenario.take_shared<CollateralManager<COLL_COIN>>();
            let config = scenario.take_shared<YieldMarketConfig<COLL_COIN>>();
            let receipt = scenario.take_from_sender<CollateralReceipt>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(3000);

            // Borrow 500 (within 70% LTV of 1000 = 700 max)
            pt_collateral::borrow(&mut manager, &config, &receipt, 500, &clk, scenario.ctx());
            assert!(pt_collateral::total_sy_borrowed(&manager) == 500);

            let (pt_coll, sy_borr, _) = pt_collateral::position_details(&manager, 0);
            assert!(pt_coll == 1000);
            assert!(sy_borr == 500);

            scenario.return_to_sender(receipt);
            clk.destroy_for_testing();
            ts::return_shared(config);
            ts::return_shared(manager);
        };

        // Repay
        ts::next_tx(&mut scenario, USER);
        {
            let mut manager = scenario.take_shared<CollateralManager<COLL_COIN>>();
            let receipt = scenario.take_from_sender<CollateralReceipt>();

            pt_collateral::repay(&mut manager, &receipt, 500, scenario.ctx());
            assert!(pt_collateral::total_sy_borrowed(&manager) == 0);

            scenario.return_to_sender(receipt);
            ts::return_shared(manager);
        };
        scenario.end();
    }

    #[test]
    fun test_withdraw_after_repay() {
        let mut scenario = setup();

        ts::next_tx(&mut scenario, USER);
        {
            let mut vault = scenario.take_shared<SYVault<COLL_COIN>>();
            let deposit = coin::mint_for_testing<COLL_COIN>(1000, scenario.ctx());
            let sy = standardized_yield::deposit(&mut vault, deposit, scenario.ctx());
            ts::return_shared(vault);

            let mut config = scenario.take_shared<YieldMarketConfig<COLL_COIN>>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(2000);
            let (pt, yt) = yield_tokenizer::mint_py(&mut config, sy, &clk, scenario.ctx());
            sui::transfer::public_transfer(yt, USER);
            clk.destroy_for_testing();
            ts::return_shared(config);

            let mut manager = scenario.take_shared<CollateralManager<COLL_COIN>>();
            let mut clk2 = clock::create_for_testing(scenario.ctx());
            clk2.set_for_testing(2000);
            let receipt = pt_collateral::deposit_collateral(&mut manager, pt, &clk2, scenario.ctx());
            sui::transfer::public_transfer(receipt, USER);
            clk2.destroy_for_testing();
            ts::return_shared(manager);
        };

        // Withdraw (no debt)
        ts::next_tx(&mut scenario, USER);
        {
            let mut manager = scenario.take_shared<CollateralManager<COLL_COIN>>();
            let receipt = scenario.take_from_sender<CollateralReceipt>();

            let withdrawn = pt_collateral::withdraw_collateral(&mut manager, receipt, scenario.ctx());
            assert!(withdrawn == 1000);
            assert!(pt_collateral::total_pt_locked(&manager) == 0);
            assert!(pt_collateral::position_count(&manager) == 0);

            ts::return_shared(manager);
        };
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = 1102)] // EExceedsLTV
    fun test_borrow_exceeds_ltv() {
        let mut scenario = setup();

        ts::next_tx(&mut scenario, USER);
        {
            let mut vault = scenario.take_shared<SYVault<COLL_COIN>>();
            let deposit = coin::mint_for_testing<COLL_COIN>(1000, scenario.ctx());
            let sy = standardized_yield::deposit(&mut vault, deposit, scenario.ctx());
            ts::return_shared(vault);

            let mut config = scenario.take_shared<YieldMarketConfig<COLL_COIN>>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(2000);
            let (pt, yt) = yield_tokenizer::mint_py(&mut config, sy, &clk, scenario.ctx());
            sui::transfer::public_transfer(yt, USER);
            clk.destroy_for_testing();
            ts::return_shared(config);

            let mut manager = scenario.take_shared<CollateralManager<COLL_COIN>>();
            let mut clk2 = clock::create_for_testing(scenario.ctx());
            clk2.set_for_testing(2000);
            let receipt = pt_collateral::deposit_collateral(&mut manager, pt, &clk2, scenario.ctx());
            sui::transfer::public_transfer(receipt, USER);
            clk2.destroy_for_testing();
            ts::return_shared(manager);
        };

        // Try to borrow 900 (exceeds ~70% LTV)
        ts::next_tx(&mut scenario, USER);
        {
            let mut manager = scenario.take_shared<CollateralManager<COLL_COIN>>();
            let config = scenario.take_shared<YieldMarketConfig<COLL_COIN>>();
            let receipt = scenario.take_from_sender<CollateralReceipt>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(3000);

            pt_collateral::borrow(&mut manager, &config, &receipt, 900, &clk, scenario.ctx());

            scenario.return_to_sender(receipt);
            clk.destroy_for_testing();
            ts::return_shared(config);
            ts::return_shared(manager);
        };
        scenario.end();
    }

    #[test]
    fun test_ltv_increases_near_maturity() {
        // LTV should be higher when closer to maturity
        let far_ltv = pt_collateral::current_ltv_wad(100_000_000, 2000, 99_998_000);
        let near_ltv = pt_collateral::current_ltv_wad(100_000_000, 99_000_000, 99_998_000);
        assert!(near_ltv > far_ltv);
    }
}
