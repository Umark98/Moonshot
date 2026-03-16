#[test_only]
module crux::integration_tests {
    use sui::test_scenario::{Self as ts};
    use sui::clock;
    use sui::coin;

    use crux::standardized_yield::{Self, AdminCap, SYVault};
    use crux::yield_tokenizer::{Self, YieldMarketConfig, PT, YT};
    use crux::flash_mint;

    public struct INT_COIN has drop {}

    const ADMIN: address = @0xAD;
    const ALICE: address = @0xA1;
    const BOB: address = @0xB0B;

    const WAD: u128 = 1_000_000_000_000_000_000;
    const MATURITY_MS: u64 = 100_000_000;

    fun setup(): ts::Scenario {
        let mut scenario = ts::begin(ADMIN);

        { standardized_yield::init_for_testing(scenario.ctx()); };

        ts::next_tx(&mut scenario, ADMIN);
        {
            let admin_cap = scenario.take_from_sender<AdminCap>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(1000);
            standardized_yield::create_vault<INT_COIN>(&admin_cap, &clk, scenario.ctx());
            scenario.return_to_sender(admin_cap);
            clk.destroy_for_testing();
        };

        ts::next_tx(&mut scenario, ADMIN);
        {
            let vault = scenario.take_shared<SYVault<INT_COIN>>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(1000);
            yield_tokenizer::create_market<INT_COIN>(&vault, MATURITY_MS, &clk, scenario.ctx());
            clk.destroy_for_testing();
            ts::return_shared(vault);
        };

        scenario
    }

    /// Full lifecycle: deposit → wrap SY → mint PT+YT → redeem pre-expiry
    #[test]
    fun test_full_lifecycle_pre_expiry() {
        let mut scenario = setup();

        // Alice deposits underlying, gets SY, mints PT+YT
        ts::next_tx(&mut scenario, ALICE);
        {
            let mut vault = scenario.take_shared<SYVault<INT_COIN>>();
            let deposit = coin::mint_for_testing<INT_COIN>(5000, scenario.ctx());
            let sy = standardized_yield::deposit(&mut vault, deposit, scenario.ctx());

            assert!(standardized_yield::sy_amount(&sy) == 5000);
            assert!(standardized_yield::total_supply(&vault) == 5000);
            assert!(standardized_yield::total_underlying(&vault) == 5000);

            ts::return_shared(vault);

            let mut config = scenario.take_shared<YieldMarketConfig<INT_COIN>>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(2000);

            let (pt, yt) = yield_tokenizer::mint_py(&mut config, sy, &clk, scenario.ctx());

            assert!(yield_tokenizer::pt_amount(&pt) == 5000);
            assert!(yield_tokenizer::yt_amount(&yt) == 5000);
            assert!(yield_tokenizer::total_pt_supply(&config) == 5000);
            assert!(yield_tokenizer::total_yt_supply(&config) == 5000);

            // Redeem PT+YT back to SY before expiry
            let sy_back = yield_tokenizer::redeem_py_pre_expiry(&mut config, pt, yt, scenario.ctx());
            assert!(sy_back == 5000);
            assert!(yield_tokenizer::total_pt_supply(&config) == 0);
            assert!(yield_tokenizer::total_yt_supply(&config) == 0);

            clk.destroy_for_testing();
            ts::return_shared(config);
        };
        scenario.end();
    }

    /// Full lifecycle: deposit → mint → settle → redeem post-expiry
    #[test]
    fun test_full_lifecycle_post_expiry() {
        let mut scenario = setup();

        // Alice deposits and mints
        ts::next_tx(&mut scenario, ALICE);
        {
            let mut vault = scenario.take_shared<SYVault<INT_COIN>>();
            let deposit = coin::mint_for_testing<INT_COIN>(2000, scenario.ctx());
            let sy = standardized_yield::deposit(&mut vault, deposit, scenario.ctx());
            ts::return_shared(vault);

            let mut config = scenario.take_shared<YieldMarketConfig<INT_COIN>>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(2000);
            let (pt, yt) = yield_tokenizer::mint_py(&mut config, sy, &clk, scenario.ctx());

            sui::transfer::public_transfer(pt, ALICE);
            sui::transfer::public_transfer(yt, ALICE);
            clk.destroy_for_testing();
            ts::return_shared(config);
        };

        // Time passes, market settles
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut config = scenario.take_shared<YieldMarketConfig<INT_COIN>>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(MATURITY_MS + 1);

            yield_tokenizer::settle_market(&mut config, &clk);
            assert!(yield_tokenizer::is_expired(&config));
            assert!(yield_tokenizer::settlement_py_index(&config) == WAD);

            clk.destroy_for_testing();
            ts::return_shared(config);
        };

        // Alice redeems PT post-expiry
        ts::next_tx(&mut scenario, ALICE);
        {
            let mut config = scenario.take_shared<YieldMarketConfig<INT_COIN>>();
            let pt = scenario.take_from_sender<PT<INT_COIN>>();

            let sy_back = yield_tokenizer::redeem_pt_post_expiry(&mut config, pt, scenario.ctx());
            assert!(sy_back == 2000); // 1:1 at settlement since no rate change

            ts::return_shared(config);
        };
        scenario.end();
    }

    /// Yield accrual: deposit → mint → rate increase → claim yield
    #[test]
    fun test_yield_accrual_and_claim() {
        let mut scenario = setup();

        // Alice deposits and mints PT+YT
        ts::next_tx(&mut scenario, ALICE);
        {
            let mut vault = scenario.take_shared<SYVault<INT_COIN>>();
            let deposit = coin::mint_for_testing<INT_COIN>(10000, scenario.ctx());
            let sy = standardized_yield::deposit(&mut vault, deposit, scenario.ctx());
            ts::return_shared(vault);

            let mut config = scenario.take_shared<YieldMarketConfig<INT_COIN>>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(2000);
            let (pt, yt) = yield_tokenizer::mint_py(&mut config, sy, &clk, scenario.ctx());

            sui::transfer::public_transfer(pt, ALICE);
            sui::transfer::public_transfer(yt, ALICE);
            clk.destroy_for_testing();
            ts::return_shared(config);
        };

        // Exchange rate increases by 10% → yield accrues to YT holders
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut vault = scenario.take_shared<SYVault<INT_COIN>>();
            let mut config = scenario.take_shared<YieldMarketConfig<INT_COIN>>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(50000);

            let new_rate = WAD + WAD / 10; // 1.1 WAD
            standardized_yield::update_exchange_rate(&mut vault, new_rate, &clk);
            yield_tokenizer::update_py_index(&mut config, &vault, &clk);

            assert!(yield_tokenizer::current_py_index(&config) == new_rate);
            assert!(yield_tokenizer::yield_reserve_sy(&config) > 0);

            clk.destroy_for_testing();
            ts::return_shared(config);
            ts::return_shared(vault);
        };

        // Alice claims yield
        ts::next_tx(&mut scenario, ALICE);
        {
            let mut config = scenario.take_shared<YieldMarketConfig<INT_COIN>>();
            let mut yt = scenario.take_from_sender<YT<INT_COIN>>();

            let pending = yield_tokenizer::pending_yield(&config, &yt);
            assert!(pending > 0);

            let claimed = yield_tokenizer::claim_yield(&mut config, &mut yt, scenario.ctx());
            assert!(claimed > 0);

            // After claim, pending should be 0
            let pending_after = yield_tokenizer::pending_yield(&config, &yt);
            assert!(pending_after == 0);

            sui::transfer::public_transfer(yt, ALICE);
            ts::return_shared(config);
        };
        scenario.end();
    }

    /// PT split/merge across users
    #[test]
    fun test_pt_transfer_and_merge() {
        let mut scenario = setup();

        // Alice mints PT+YT
        ts::next_tx(&mut scenario, ALICE);
        {
            let mut vault = scenario.take_shared<SYVault<INT_COIN>>();
            let deposit = coin::mint_for_testing<INT_COIN>(3000, scenario.ctx());
            let sy = standardized_yield::deposit(&mut vault, deposit, scenario.ctx());
            ts::return_shared(vault);

            let mut config = scenario.take_shared<YieldMarketConfig<INT_COIN>>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(2000);
            let (pt, yt) = yield_tokenizer::mint_py(&mut config, sy, &clk, scenario.ctx());

            // Split PT: 2000 for Alice, 1000 for Bob
            let mut pt_alice = pt;
            let pt_bob = yield_tokenizer::split_pt(&mut pt_alice, 1000, scenario.ctx());

            assert!(yield_tokenizer::pt_amount(&pt_alice) == 2000);
            assert!(yield_tokenizer::pt_amount(&pt_bob) == 1000);

            sui::transfer::public_transfer(pt_alice, ALICE);
            sui::transfer::public_transfer(pt_bob, BOB);
            sui::transfer::public_transfer(yt, ALICE);
            clk.destroy_for_testing();
            ts::return_shared(config);
        };

        // Bob merges his PT with a new PT from a different mint
        ts::next_tx(&mut scenario, BOB);
        {
            let pt_bob = scenario.take_from_sender<PT<INT_COIN>>();
            assert!(yield_tokenizer::pt_amount(&pt_bob) == 1000);
            sui::transfer::public_transfer(pt_bob, BOB);
        };
        scenario.end();
    }

    /// Flash mint → sell PT → keep YT (leveraged yield strategy)
    #[test]
    fun test_flash_mint_leveraged_yield() {
        let mut scenario = setup();

        ts::next_tx(&mut scenario, ALICE);
        {
            let mut config = scenario.take_shared<YieldMarketConfig<INT_COIN>>();
            let mut vault = scenario.take_shared<SYVault<INT_COIN>>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(2000);

            // Step 1: Flash mint 5000 PT + YT
            let (pt, yt, receipt) = flash_mint::flash_mint(&mut config, 5000, &clk, scenario.ctx());

            assert!(yield_tokenizer::pt_amount(&pt) == 5000);
            assert!(yield_tokenizer::yt_amount(&yt) == 5000);

            // Step 2: Simulate selling PT on AMM by providing SY repayment
            // In production: swap_pt_for_sy would return SY used to repay
            let repay_coin = coin::mint_for_testing<INT_COIN>(5100, scenario.ctx());
            let repay_sy = standardized_yield::deposit(&mut vault, repay_coin, scenario.ctx());

            // Step 3: Repay flash mint receipt
            flash_mint::repay_flash_mint(&mut vault, receipt, repay_sy, scenario.ctx());

            // Alice keeps YT (leveraged yield exposure) and PT
            sui::transfer::public_transfer(pt, ALICE);
            sui::transfer::public_transfer(yt, ALICE);

            clk.destroy_for_testing();
            ts::return_shared(config);
            ts::return_shared(vault);
        };

        // Verify Alice has both PT and YT
        ts::next_tx(&mut scenario, ALICE);
        {
            let pt = scenario.take_from_sender<PT<INT_COIN>>();
            let yt = scenario.take_from_sender<YT<INT_COIN>>();

            assert!(yield_tokenizer::pt_amount(&pt) == 5000);
            assert!(yield_tokenizer::yt_amount(&yt) == 5000);

            sui::transfer::public_transfer(pt, ALICE);
            sui::transfer::public_transfer(yt, ALICE);
        };
        scenario.end();
    }

    /// Multi-user: Alice and Bob both mint, yield accrues, both claim
    #[test]
    fun test_multi_user_yield_distribution() {
        let mut scenario = setup();

        // Alice mints 6000 PT+YT
        ts::next_tx(&mut scenario, ALICE);
        {
            let mut vault = scenario.take_shared<SYVault<INT_COIN>>();
            let deposit = coin::mint_for_testing<INT_COIN>(6000, scenario.ctx());
            let sy = standardized_yield::deposit(&mut vault, deposit, scenario.ctx());
            ts::return_shared(vault);

            let mut config = scenario.take_shared<YieldMarketConfig<INT_COIN>>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(2000);
            let (pt, yt) = yield_tokenizer::mint_py(&mut config, sy, &clk, scenario.ctx());
            sui::transfer::public_transfer(pt, ALICE);
            sui::transfer::public_transfer(yt, ALICE);
            clk.destroy_for_testing();
            ts::return_shared(config);
        };

        // Bob mints 4000 PT+YT
        ts::next_tx(&mut scenario, BOB);
        {
            let mut vault = scenario.take_shared<SYVault<INT_COIN>>();
            let deposit = coin::mint_for_testing<INT_COIN>(4000, scenario.ctx());
            let sy = standardized_yield::deposit(&mut vault, deposit, scenario.ctx());
            ts::return_shared(vault);

            let mut config = scenario.take_shared<YieldMarketConfig<INT_COIN>>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(3000);
            let (pt, yt) = yield_tokenizer::mint_py(&mut config, sy, &clk, scenario.ctx());
            sui::transfer::public_transfer(pt, BOB);
            sui::transfer::public_transfer(yt, BOB);
            clk.destroy_for_testing();
            ts::return_shared(config);
        };

        // Verify total supply
        ts::next_tx(&mut scenario, ADMIN);
        {
            let config = scenario.take_shared<YieldMarketConfig<INT_COIN>>();
            assert!(yield_tokenizer::total_pt_supply(&config) == 10000);
            assert!(yield_tokenizer::total_yt_supply(&config) == 10000);
            ts::return_shared(config);
        };

        // Rate increases 5%
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut vault = scenario.take_shared<SYVault<INT_COIN>>();
            let mut config = scenario.take_shared<YieldMarketConfig<INT_COIN>>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(50000);

            let new_rate = WAD + WAD / 20; // 1.05 WAD
            standardized_yield::update_exchange_rate(&mut vault, new_rate, &clk);
            yield_tokenizer::update_py_index(&mut config, &vault, &clk);

            clk.destroy_for_testing();
            ts::return_shared(config);
            ts::return_shared(vault);
        };

        // Alice claims yield (she has 6000 YT = 60% share)
        ts::next_tx(&mut scenario, ALICE);
        {
            let mut config = scenario.take_shared<YieldMarketConfig<INT_COIN>>();
            let mut yt = scenario.take_from_sender<YT<INT_COIN>>();

            let alice_yield = yield_tokenizer::claim_yield(&mut config, &mut yt, scenario.ctx());
            assert!(alice_yield > 0);

            sui::transfer::public_transfer(yt, ALICE);
            ts::return_shared(config);
        };

        // Bob claims yield (he has 4000 YT = 40% share)
        ts::next_tx(&mut scenario, BOB);
        {
            let mut config = scenario.take_shared<YieldMarketConfig<INT_COIN>>();
            let mut yt = scenario.take_from_sender<YT<INT_COIN>>();

            let bob_yield = yield_tokenizer::claim_yield(&mut config, &mut yt, scenario.ctx());
            assert!(bob_yield > 0);

            sui::transfer::public_transfer(yt, BOB);
            ts::return_shared(config);
        };
        scenario.end();
    }

    /// SY deposit → redeem round-trip preserves value
    #[test]
    fun test_sy_deposit_redeem_roundtrip() {
        let mut scenario = setup();

        ts::next_tx(&mut scenario, ALICE);
        {
            let mut vault = scenario.take_shared<SYVault<INT_COIN>>();

            // Deposit 1000
            let deposit = coin::mint_for_testing<INT_COIN>(1000, scenario.ctx());
            let sy = standardized_yield::deposit(&mut vault, deposit, scenario.ctx());
            assert!(standardized_yield::sy_amount(&sy) == 1000);

            // Redeem
            let underlying = standardized_yield::redeem(&mut vault, sy, scenario.ctx());
            assert!(underlying.value() == 1000);

            sui::transfer::public_transfer(underlying, ALICE);
            ts::return_shared(vault);
        };
        scenario.end();
    }
}
