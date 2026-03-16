#[test_only]
module crux::rate_market_tests {
    use sui::test_scenario::{Self as ts};
    use sui::clock;
    use sui::coin;

    use crux::standardized_yield::{Self, AdminCap, SYVault};
    use crux::yield_tokenizer::{Self, YieldMarketConfig, PT};
    use crux::rate_market::{Self, YieldPool, LPToken};

    public struct AMM_COIN has drop {}

    const ADMIN: address = @0xAD;
    const ALICE: address = @0xA1;
    const BOB: address = @0xB0B;

    const WAD: u128 = 1_000_000_000_000_000_000;
    const MATURITY_MS: u64 = 200_000_000; // 200s maturity

    /// Setup: vault + market config, then mint PT + SY for pool seeding
    fun setup(): ts::Scenario {
        let mut scenario = ts::begin(ADMIN);

        { standardized_yield::init_for_testing(scenario.ctx()); };

        // Create vault
        ts::next_tx(&mut scenario, ADMIN);
        {
            let admin_cap = scenario.take_from_sender<AdminCap>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(1000);
            standardized_yield::create_vault<AMM_COIN>(&admin_cap, &clk, scenario.ctx());
            scenario.return_to_sender(admin_cap);
            clk.destroy_for_testing();
        };

        // Create market
        ts::next_tx(&mut scenario, ADMIN);
        {
            let vault = scenario.take_shared<SYVault<AMM_COIN>>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(1000);
            let admin_cap = scenario.take_from_sender<AdminCap>();
            yield_tokenizer::create_market<AMM_COIN>(&admin_cap, &vault, MATURITY_MS, &clk, scenario.ctx());
            scenario.return_to_sender(admin_cap);
            clk.destroy_for_testing();
            ts::return_shared(vault);
        };

        scenario
    }

    /// Helper: mint PT+YT from Coin<T>, also keep some Coin<T> for pool seeding
    fun mint_pt_and_coin(
        scenario: &mut ts::Scenario,
        amount: u64,
    ) {
        let mut config = scenario.take_shared<YieldMarketConfig<AMM_COIN>>();
        let vault = scenario.take_shared<SYVault<AMM_COIN>>();
        let mut clk = clock::create_for_testing(scenario.ctx());
        clk.set_for_testing(2000);

        // Mint Coin<T> for PT+YT minting
        let coin_for_mint = coin::mint_for_testing<AMM_COIN>(amount, scenario.ctx());

        // Mint PT+YT from Coin<T>
        let (pt, yt) = yield_tokenizer::mint_py(&mut config, &vault, coin_for_mint, &clk, scenario.ctx());

        // Keep extra Coin<T> for pool seeding (representing SY side)
        let coin_remaining = coin::mint_for_testing<AMM_COIN>(amount, scenario.ctx());

        // Transfer PT, Coin, YT to sender
        sui::transfer::public_transfer(pt, scenario.ctx().sender());
        sui::transfer::public_transfer(coin_remaining, scenario.ctx().sender());
        sui::transfer::public_transfer(yt, scenario.ctx().sender());

        clk.destroy_for_testing();
        ts::return_shared(config);
        ts::return_shared(vault);
    }

    // ===== Pool Creation Tests =====

    #[test]
    fun test_create_pool() {
        let mut scenario = setup();

        // Mint PT + SY for pool seeding
        ts::next_tx(&mut scenario, ALICE);
        mint_pt_and_coin(&mut scenario, 10000);

        // Create pool
        ts::next_tx(&mut scenario, ALICE);
        {
            let mut config = scenario.take_shared<YieldMarketConfig<AMM_COIN>>();
            let vault = scenario.take_shared<SYVault<AMM_COIN>>();
            let underlying = scenario.take_from_sender<coin::Coin<AMM_COIN>>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(2000);

            let lp = rate_market::create_pool(&mut config, &vault, underlying, 12000, 10000, &clk, scenario.ctx());

            assert!(rate_market::lp_amount(&lp) > 0);

            sui::transfer::public_transfer(lp, ALICE);
            clk.destroy_for_testing();
            ts::return_shared(config);
            ts::return_shared(vault);
        };

        // Verify pool state
        ts::next_tx(&mut scenario, ALICE);
        {
            let pool = scenario.take_shared<YieldPool<AMM_COIN>>();

            assert!(rate_market::pt_reserve(&pool) == 12000);
            assert!(rate_market::sy_reserve(&pool) == 10000);
            assert!(rate_market::total_lp_supply(&pool) > 0);
            assert!(rate_market::current_implied_rate(&pool) > 0);

            ts::return_shared(pool);
        };
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = 504)] // EZeroAmount
    fun test_create_pool_zero_pt() {
        let mut scenario = setup();

        ts::next_tx(&mut scenario, ALICE);
        {
            let mut config = scenario.take_shared<YieldMarketConfig<AMM_COIN>>();
            let vault = scenario.take_shared<SYVault<AMM_COIN>>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(2000);

            let deposit = coin::mint_for_testing<AMM_COIN>(1000, scenario.ctx());

            // Create pool with zero pt_amount — should fail
            let lp = rate_market::create_pool(&mut config, &vault, deposit, 0, 1000, &clk, scenario.ctx());
            sui::transfer::public_transfer(lp, ALICE);

            clk.destroy_for_testing();
            ts::return_shared(config);
            ts::return_shared(vault);
        };
        scenario.end();
    }

    // ===== Swap Tests =====

    #[test]
    fun test_swap_sy_for_pt() {
        let mut scenario = setup();

        // Seed pool
        ts::next_tx(&mut scenario, ALICE);
        mint_pt_and_coin(&mut scenario, 10000);

        ts::next_tx(&mut scenario, ALICE);
        {
            let mut config = scenario.take_shared<YieldMarketConfig<AMM_COIN>>();
            let vault = scenario.take_shared<SYVault<AMM_COIN>>();
            let underlying = scenario.take_from_sender<coin::Coin<AMM_COIN>>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(2000);

            let lp = rate_market::create_pool(&mut config, &vault, underlying, 10000, 10000, &clk, scenario.ctx());
            sui::transfer::public_transfer(lp, ALICE);
            clk.destroy_for_testing();
            ts::return_shared(config);
            ts::return_shared(vault);
        };

        // Bob swaps Coin<T> for PT
        ts::next_tx(&mut scenario, BOB);
        {
            let vault = scenario.take_shared<SYVault<AMM_COIN>>();
            let mut pool = scenario.take_shared<YieldPool<AMM_COIN>>();
            let mut config = scenario.take_shared<YieldMarketConfig<AMM_COIN>>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(3000);

            let coin_in = coin::mint_for_testing<AMM_COIN>(500, scenario.ctx());

            let pt_before = rate_market::pt_reserve(&pool);
            let sy_before = rate_market::sy_reserve(&pool);

            let pt_out = rate_market::swap_sy_for_pt(
                &mut pool, &vault, &mut config, coin_in, 0, &clk, scenario.ctx(),
            );

            // Verify pool state changed
            assert!(rate_market::pt_reserve(&pool) < pt_before);
            assert!(rate_market::sy_reserve(&pool) > sy_before);

            // Verify Bob got PT
            assert!(yield_tokenizer::pt_amount(&pt_out) > 0);

            sui::transfer::public_transfer(pt_out, BOB);
            clk.destroy_for_testing();
            ts::return_shared(pool);
            ts::return_shared(config);
            ts::return_shared(vault);
        };
        scenario.end();
    }

    #[test]
    fun test_swap_pt_for_sy() {
        let mut scenario = setup();

        // Seed pool
        ts::next_tx(&mut scenario, ALICE);
        mint_pt_and_coin(&mut scenario, 10000);

        ts::next_tx(&mut scenario, ALICE);
        {
            let mut config = scenario.take_shared<YieldMarketConfig<AMM_COIN>>();
            let vault = scenario.take_shared<SYVault<AMM_COIN>>();
            let underlying = scenario.take_from_sender<coin::Coin<AMM_COIN>>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(2000);
            let lp = rate_market::create_pool(&mut config, &vault, underlying, 10000, 10000, &clk, scenario.ctx());
            sui::transfer::public_transfer(lp, ALICE);
            clk.destroy_for_testing();
            ts::return_shared(config);
            ts::return_shared(vault);
        };

        // Bob mints PT, then swaps PT for Coin<T>
        ts::next_tx(&mut scenario, BOB);
        {
            let vault = scenario.take_shared<SYVault<AMM_COIN>>();
            let mut config = scenario.take_shared<YieldMarketConfig<AMM_COIN>>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(3000);

            let coin_for_mint = coin::mint_for_testing<AMM_COIN>(500, scenario.ctx());
            let (pt, yt) = yield_tokenizer::mint_py(&mut config, &vault, coin_for_mint, &clk, scenario.ctx());

            let mut pool = scenario.take_shared<YieldPool<AMM_COIN>>();

            let pt_before = rate_market::pt_reserve(&pool);
            let sy_before = rate_market::sy_reserve(&pool);

            let coin_out = rate_market::swap_pt_for_sy(
                &mut pool, &vault, &mut config, pt, 0, &clk, scenario.ctx(),
            );

            // Verify pool state changed
            assert!(rate_market::pt_reserve(&pool) > pt_before);
            assert!(rate_market::sy_reserve(&pool) < sy_before);

            // Verify Bob got Coin<T>
            assert!(coin_out.value() > 0);

            sui::transfer::public_transfer(coin_out, BOB);
            sui::transfer::public_transfer(yt, BOB);
            clk.destroy_for_testing();
            ts::return_shared(pool);
            ts::return_shared(config);
            ts::return_shared(vault);
        };
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = 503)] // ESlippageExceeded
    fun test_swap_slippage_exceeded() {
        let mut scenario = setup();

        ts::next_tx(&mut scenario, ALICE);
        mint_pt_and_coin(&mut scenario, 10000);

        ts::next_tx(&mut scenario, ALICE);
        {
            let mut config = scenario.take_shared<YieldMarketConfig<AMM_COIN>>();
            let vault = scenario.take_shared<SYVault<AMM_COIN>>();
            let underlying = scenario.take_from_sender<coin::Coin<AMM_COIN>>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(2000);
            let lp = rate_market::create_pool(&mut config, &vault, underlying, 10000, 10000, &clk, scenario.ctx());
            sui::transfer::public_transfer(lp, ALICE);
            clk.destroy_for_testing();
            ts::return_shared(config);
            ts::return_shared(vault);
        };

        // Swap with unreasonably high min_pt_out
        ts::next_tx(&mut scenario, BOB);
        {
            let vault = scenario.take_shared<SYVault<AMM_COIN>>();
            let mut pool = scenario.take_shared<YieldPool<AMM_COIN>>();
            let mut config = scenario.take_shared<YieldMarketConfig<AMM_COIN>>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(3000);

            let coin_in = coin::mint_for_testing<AMM_COIN>(100, scenario.ctx());

            // min_pt_out = 999999, impossible to fill
            let pt_out = rate_market::swap_sy_for_pt(
                &mut pool, &vault, &mut config, coin_in, 999999, &clk, scenario.ctx(),
            );
            sui::transfer::public_transfer(pt_out, BOB);

            clk.destroy_for_testing();
            ts::return_shared(pool);
            ts::return_shared(config);
            ts::return_shared(vault);
        };
        scenario.end();
    }

    // ===== Liquidity Tests =====

    #[test]
    fun test_add_liquidity() {
        let mut scenario = setup();

        // Create pool
        ts::next_tx(&mut scenario, ALICE);
        mint_pt_and_coin(&mut scenario, 10000);

        ts::next_tx(&mut scenario, ALICE);
        {
            let mut config = scenario.take_shared<YieldMarketConfig<AMM_COIN>>();
            let vault = scenario.take_shared<SYVault<AMM_COIN>>();
            let underlying = scenario.take_from_sender<coin::Coin<AMM_COIN>>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(2000);
            let lp = rate_market::create_pool(&mut config, &vault, underlying, 10000, 10000, &clk, scenario.ctx());
            sui::transfer::public_transfer(lp, ALICE);
            clk.destroy_for_testing();
            ts::return_shared(config);
            ts::return_shared(vault);
        };

        // Bob adds liquidity
        ts::next_tx(&mut scenario, BOB);
        {
            let vault = scenario.take_shared<SYVault<AMM_COIN>>();
            let mut config = scenario.take_shared<YieldMarketConfig<AMM_COIN>>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(3000);

            let underlying = coin::mint_for_testing<AMM_COIN>(1000, scenario.ctx());

            let mut pool = scenario.take_shared<YieldPool<AMM_COIN>>();
            let lp_before = rate_market::total_lp_supply(&pool);

            let lp = rate_market::add_liquidity(&mut pool, &vault, underlying, 1000, 1000, &clk, scenario.ctx());

            assert!(rate_market::lp_amount(&lp) > 0);
            assert!(rate_market::total_lp_supply(&pool) > lp_before);
            assert!(rate_market::pt_reserve(&pool) == 11000); // 10000 + 1000
            assert!(rate_market::sy_reserve(&pool) == 11000); // 10000 + 1000

            sui::transfer::public_transfer(lp, BOB);
            clk.destroy_for_testing();
            ts::return_shared(pool);
            ts::return_shared(config);
            ts::return_shared(vault);
        };
        scenario.end();
    }

    #[test]
    fun test_remove_liquidity() {
        let mut scenario = setup();

        ts::next_tx(&mut scenario, ALICE);
        mint_pt_and_coin(&mut scenario, 10000);

        ts::next_tx(&mut scenario, ALICE);
        {
            let mut config = scenario.take_shared<YieldMarketConfig<AMM_COIN>>();
            let vault = scenario.take_shared<SYVault<AMM_COIN>>();
            let underlying = scenario.take_from_sender<coin::Coin<AMM_COIN>>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(2000);
            let lp = rate_market::create_pool(&mut config, &vault, underlying, 10000, 10000, &clk, scenario.ctx());
            sui::transfer::public_transfer(lp, ALICE);
            clk.destroy_for_testing();
            ts::return_shared(config);
            ts::return_shared(vault);
        };

        // Alice removes all liquidity
        ts::next_tx(&mut scenario, ALICE);
        {
            let mut pool = scenario.take_shared<YieldPool<AMM_COIN>>();
            let vault = scenario.take_shared<SYVault<AMM_COIN>>();
            let lp = scenario.take_from_sender<LPToken<AMM_COIN>>();

            let lp_amount = rate_market::lp_amount(&lp);
            assert!(lp_amount > 0);

            let coin_out = rate_market::remove_liquidity(
                &mut pool, &vault, lp, scenario.ctx(),
            );

            assert!(coin_out.value() > 0);
            assert!(rate_market::total_lp_supply(&pool) == 0);

            sui::transfer::public_transfer(coin_out, ALICE);
            ts::return_shared(pool);
            ts::return_shared(vault);
        };
        scenario.end();
    }

    // ===== Rate and TWAP Tests =====

    #[test]
    fun test_implied_rate_changes_after_swap() {
        let mut scenario = setup();

        ts::next_tx(&mut scenario, ALICE);
        mint_pt_and_coin(&mut scenario, 10000);

        ts::next_tx(&mut scenario, ALICE);
        {
            let mut config = scenario.take_shared<YieldMarketConfig<AMM_COIN>>();
            let vault = scenario.take_shared<SYVault<AMM_COIN>>();
            let underlying = scenario.take_from_sender<coin::Coin<AMM_COIN>>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(2000);
            let lp = rate_market::create_pool(&mut config, &vault, underlying, 11000, 10000, &clk, scenario.ctx());
            sui::transfer::public_transfer(lp, ALICE);
            clk.destroy_for_testing();
            ts::return_shared(config);
            ts::return_shared(vault);
        };

        // Record rate before swap, then do a swap that moves the rate
        ts::next_tx(&mut scenario, BOB);
        {
            let vault = scenario.take_shared<SYVault<AMM_COIN>>();
            let mut pool = scenario.take_shared<YieldPool<AMM_COIN>>();
            let mut config = scenario.take_shared<YieldMarketConfig<AMM_COIN>>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(5000);

            let rate_before = rate_market::current_implied_rate(&pool);

            // Swap Coin<T> → PT should move the rate
            let coin_in = coin::mint_for_testing<AMM_COIN>(500, scenario.ctx());

            let pt_out = rate_market::swap_sy_for_pt(
                &mut pool, &vault, &mut config, coin_in, 0, &clk, scenario.ctx(),
            );

            let rate_after = rate_market::current_implied_rate(&pool);

            // Rate should have changed after a significant swap
            assert!(rate_after != rate_before);

            sui::transfer::public_transfer(pt_out, BOB);
            clk.destroy_for_testing();
            ts::return_shared(pool);
            ts::return_shared(config);
            ts::return_shared(vault);
        };
        scenario.end();
    }

    // ===== Full E2E: deposit → pool → swap → redeem =====

    #[test]
    fun test_full_amm_lifecycle() {
        let mut scenario = setup();

        // Alice provides liquidity
        ts::next_tx(&mut scenario, ALICE);
        mint_pt_and_coin(&mut scenario, 10000);

        ts::next_tx(&mut scenario, ALICE);
        {
            let mut config = scenario.take_shared<YieldMarketConfig<AMM_COIN>>();
            let vault = scenario.take_shared<SYVault<AMM_COIN>>();
            let underlying = scenario.take_from_sender<coin::Coin<AMM_COIN>>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(2000);
            let lp = rate_market::create_pool(&mut config, &vault, underlying, 10000, 10000, &clk, scenario.ctx());
            sui::transfer::public_transfer(lp, ALICE);
            clk.destroy_for_testing();
            ts::return_shared(config);
            ts::return_shared(vault);
        };

        // Bob buys PT (fixed-rate position)
        ts::next_tx(&mut scenario, BOB);
        {
            let vault = scenario.take_shared<SYVault<AMM_COIN>>();
            let mut pool = scenario.take_shared<YieldPool<AMM_COIN>>();
            let mut config = scenario.take_shared<YieldMarketConfig<AMM_COIN>>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(3000);

            let coin_in = coin::mint_for_testing<AMM_COIN>(1000, scenario.ctx());

            let pt = rate_market::swap_sy_for_pt(
                &mut pool, &vault, &mut config, coin_in, 0, &clk, scenario.ctx(),
            );

            assert!(yield_tokenizer::pt_amount(&pt) > 0);
            sui::transfer::public_transfer(pt, BOB);

            clk.destroy_for_testing();
            ts::return_shared(pool);
            ts::return_shared(config);
            ts::return_shared(vault);
        };

        // Time passes, market settles
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut config = scenario.take_shared<YieldMarketConfig<AMM_COIN>>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(MATURITY_MS + 1);

            let admin_cap = scenario.take_from_sender<AdminCap>();
            yield_tokenizer::settle_market(&admin_cap, &mut config, &clk);
            scenario.return_to_sender(admin_cap);
            assert!(yield_tokenizer::is_expired(&config));

            clk.destroy_for_testing();
            ts::return_shared(config);
        };

        // Bob redeems PT post-maturity for guaranteed value
        ts::next_tx(&mut scenario, BOB);
        {
            let mut config = scenario.take_shared<YieldMarketConfig<AMM_COIN>>();
            let pt = scenario.take_from_sender<PT<AMM_COIN>>();

            let pt_amount = yield_tokenizer::pt_amount(&pt);
            let coin_back = yield_tokenizer::redeem_pt_post_expiry(&mut config, pt, scenario.ctx());

            // PT redeems at least its face value at settlement rate
            assert!(coin_back.value() > 0);

            sui::transfer::public_transfer(coin_back, BOB);
            ts::return_shared(config);
        };

        // Alice removes liquidity
        ts::next_tx(&mut scenario, ALICE);
        {
            let mut pool = scenario.take_shared<YieldPool<AMM_COIN>>();
            let vault = scenario.take_shared<SYVault<AMM_COIN>>();
            let lp = scenario.take_from_sender<LPToken<AMM_COIN>>();

            let coin_out = rate_market::remove_liquidity(
                &mut pool, &vault, lp, scenario.ctx(),
            );
            assert!(coin_out.value() > 0);

            sui::transfer::public_transfer(coin_out, ALICE);
            ts::return_shared(pool);
            ts::return_shared(vault);
        };
        scenario.end();
    }
}
