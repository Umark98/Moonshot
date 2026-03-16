#[test_only]
module crux::flash_mint_tests {
    use sui::test_scenario::{Self as ts};
    use sui::clock;
    use sui::coin;

    use crux::standardized_yield::{Self, AdminCap, SYVault};
    use crux::yield_tokenizer::{Self, YieldMarketConfig, PT, YT};
    use crux::flash_mint;

    public struct FM_COIN has drop {}

    const ADMIN: address = @0xAD;
    const USER: address = @0xB0B;

    const MATURITY_MS: u64 = 100_000_000;

    fun setup(): ts::Scenario {
        let mut scenario = ts::begin(ADMIN);

        { standardized_yield::init_for_testing(scenario.ctx()); };

        ts::next_tx(&mut scenario, ADMIN);
        {
            let admin_cap = scenario.take_from_sender<AdminCap>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(1000);
            standardized_yield::create_vault<FM_COIN>(&admin_cap, &clk, scenario.ctx());
            scenario.return_to_sender(admin_cap);
            clk.destroy_for_testing();
        };

        ts::next_tx(&mut scenario, ADMIN);
        {
            let vault = scenario.take_shared<SYVault<FM_COIN>>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(1000);
            yield_tokenizer::create_market<FM_COIN>(&vault, MATURITY_MS, &clk, scenario.ctx());
            clk.destroy_for_testing();
            ts::return_shared(vault);
        };

        scenario
    }

    #[test]
    fun test_flash_mint_and_repay() {
        let mut scenario = setup();

        ts::next_tx(&mut scenario, USER);
        {
            let mut config = scenario.take_shared<YieldMarketConfig<FM_COIN>>();
            let mut vault = scenario.take_shared<SYVault<FM_COIN>>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(2000);

            // Flash mint 1000 PT + YT
            let (pt, yt, receipt) = flash_mint::flash_mint(&mut config, 1000, &clk, scenario.ctx());

            assert!(yield_tokenizer::pt_amount(&pt) == 1000);
            assert!(yield_tokenizer::yt_amount(&yt) == 1000);
            assert!(yield_tokenizer::total_pt_supply(&config) == 1000);
            assert!(yield_tokenizer::total_yt_supply(&config) == 1000);

            // The receipt requires repayment
            let owed = flash_mint::amount_owed(&receipt);
            assert!(owed >= 1000); // 1000 + fee

            // Create SY to repay (simulate selling PT on AMM)
            let repay_coin = coin::mint_for_testing<FM_COIN>(1100, scenario.ctx());
            let repay_sy = standardized_yield::deposit(&mut vault, repay_coin, scenario.ctx());

            // Repay flash mint
            flash_mint::repay_flash_mint(&mut vault, receipt, repay_sy, scenario.ctx());

            sui::transfer::public_transfer(pt, USER);
            sui::transfer::public_transfer(yt, USER);
            clk.destroy_for_testing();
            ts::return_shared(config);
            ts::return_shared(vault);
        };
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = 400)] // EInsufficientRepayment
    fun test_flash_mint_insufficient_repayment() {
        let mut scenario = setup();

        ts::next_tx(&mut scenario, USER);
        {
            let mut config = scenario.take_shared<YieldMarketConfig<FM_COIN>>();
            let mut vault = scenario.take_shared<SYVault<FM_COIN>>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(2000);

            let (pt, yt, receipt) = flash_mint::flash_mint(&mut config, 1000, &clk, scenario.ctx());

            // Try to repay with less than owed
            let repay_coin = coin::mint_for_testing<FM_COIN>(500, scenario.ctx());
            let repay_sy = standardized_yield::deposit(&mut vault, repay_coin, scenario.ctx());

            flash_mint::repay_flash_mint(&mut vault, receipt, repay_sy, scenario.ctx());

            sui::transfer::public_transfer(pt, USER);
            sui::transfer::public_transfer(yt, USER);
            clk.destroy_for_testing();
            ts::return_shared(config);
            ts::return_shared(vault);
        };
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = 401)] // EZeroAmount
    fun test_flash_mint_zero_amount() {
        let mut scenario = setup();

        ts::next_tx(&mut scenario, USER);
        {
            let mut config = scenario.take_shared<YieldMarketConfig<FM_COIN>>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(2000);

            let (pt, yt, receipt) = flash_mint::flash_mint(&mut config, 0, &clk, scenario.ctx());

            sui::transfer::public_transfer(pt, USER);
            sui::transfer::public_transfer(yt, USER);
            // receipt can't be dropped — but we abort before needing to handle it
            let _ = receipt;
            clk.destroy_for_testing();
            ts::return_shared(config);
        };
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = 402)] // EMarketExpired
    fun test_flash_mint_after_expiry() {
        let mut scenario = setup();

        // Settle market
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut config = scenario.take_shared<YieldMarketConfig<FM_COIN>>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(MATURITY_MS + 1);
            yield_tokenizer::settle_market(&mut config, &clk);
            clk.destroy_for_testing();
            ts::return_shared(config);
        };

        ts::next_tx(&mut scenario, USER);
        {
            let mut config = scenario.take_shared<YieldMarketConfig<FM_COIN>>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(MATURITY_MS + 2);

            let (pt, yt, receipt) = flash_mint::flash_mint(&mut config, 1000, &clk, scenario.ctx());

            sui::transfer::public_transfer(pt, USER);
            sui::transfer::public_transfer(yt, USER);
            let _ = receipt;
            clk.destroy_for_testing();
            ts::return_shared(config);
        };
        scenario.end();
    }

    #[test]
    fun test_flash_mint_fee_calculation() {
        let mut scenario = setup();

        ts::next_tx(&mut scenario, USER);
        {
            let mut config = scenario.take_shared<YieldMarketConfig<FM_COIN>>();
            let mut vault = scenario.take_shared<SYVault<FM_COIN>>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(2000);

            // Flash mint 10000 — fee should be 1 (0.01% of 10000 = 1)
            let (pt, yt, receipt) = flash_mint::flash_mint(&mut config, 10000, &clk, scenario.ctx());
            let fee = flash_mint::receipt_fee(&receipt);
            assert!(fee == 1); // 10000 * 0.0001 = 1

            let repay_coin = coin::mint_for_testing<FM_COIN>(11000, scenario.ctx());
            let repay_sy = standardized_yield::deposit(&mut vault, repay_coin, scenario.ctx());
            flash_mint::repay_flash_mint(&mut vault, receipt, repay_sy, scenario.ctx());

            sui::transfer::public_transfer(pt, USER);
            sui::transfer::public_transfer(yt, USER);
            clk.destroy_for_testing();
            ts::return_shared(config);
            ts::return_shared(vault);
        };
        scenario.end();
    }
}
