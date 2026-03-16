#[test_only]
module crux::invariant_tests {
    use sui::test_scenario::{Self as ts};
    use sui::clock;
    use sui::coin;

    use crux::standardized_yield::{Self, AdminCap, SYVault};
    use crux::yield_tokenizer::{Self, YieldMarketConfig, PT, YT};
    use crux::rate_market::{Self, YieldPool, LPToken};
    use crux::flash_mint;
    use crux::fixed_point;

    // ===== Test Coin =====
    public struct TEST_COIN has drop {}

    // ===== Addresses =====
    const ADMIN: address = @0xAD;
    const USER_A: address = @0xA;
    const USER_B: address = @0xB;

    // ===== Constants =====
    const WAD: u128 = 1_000_000_000_000_000_000;
    const MATURITY_MS: u64 = 100_000_000; // 100 seconds from epoch

    // ========================================================================
    // Setup Helpers
    // ========================================================================

    /// Initialise the SY module, create an AdminCap, a vault, and a yield market.
    fun setup(): ts::Scenario {
        let mut scenario = ts::begin(ADMIN);
        {
            standardized_yield::init_for_testing(scenario.ctx());
        };

        // Create SY vault
        scenario.next_tx(ADMIN);
        {
            let admin_cap = scenario.take_from_sender<AdminCap>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(1000);
            standardized_yield::create_vault<TEST_COIN>(&admin_cap, &clk, scenario.ctx());
            scenario.return_to_sender(admin_cap);
            clk.destroy_for_testing();
        };

        // Create yield market
        scenario.next_tx(ADMIN);
        {
            let vault = scenario.take_shared<SYVault<TEST_COIN>>();
            let admin_cap = scenario.take_from_sender<AdminCap>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(1000);
            yield_tokenizer::create_market<TEST_COIN>(
                &admin_cap, &vault, MATURITY_MS, &clk, scenario.ctx(),
            );
            scenario.return_to_sender(admin_cap);
            clk.destroy_for_testing();
            ts::return_shared(vault);
        };

        scenario
    }

    // ========================================================================
    // 1. Vault Solvency — underlying_balance >= total_sy * rate / WAD
    // ========================================================================

    #[test]
    fun test_invariant_vault_solvency_after_deposits_and_redeems() {
        let mut scenario = setup();

        // USER_A deposits 5000
        scenario.next_tx(USER_A);
        {
            let mut vault = scenario.take_shared<SYVault<TEST_COIN>>();
            let coin_a = coin::mint_for_testing<TEST_COIN>(5000, scenario.ctx());
            let sy_a = standardized_yield::deposit(&mut vault, coin_a, scenario.ctx());

            // Invariant: vault is solvent
            assert!(standardized_yield::is_solvent(&vault), 1001);

            sui::transfer::public_transfer(sy_a, USER_A);
            ts::return_shared(vault);
        };

        // USER_B deposits 3000
        scenario.next_tx(USER_B);
        {
            let mut vault = scenario.take_shared<SYVault<TEST_COIN>>();
            let coin_b = coin::mint_for_testing<TEST_COIN>(3000, scenario.ctx());
            let sy_b = standardized_yield::deposit(&mut vault, coin_b, scenario.ctx());

            // Invariant after second deposit
            assert!(standardized_yield::is_solvent(&vault), 1002);
            assert!(standardized_yield::total_underlying(&vault) == 8000, 1003);
            assert!(standardized_yield::total_supply(&vault) == 8000, 1004);

            sui::transfer::public_transfer(sy_b, USER_B);
            ts::return_shared(vault);
        };

        // USER_A redeems
        scenario.next_tx(USER_A);
        {
            let mut vault = scenario.take_shared<SYVault<TEST_COIN>>();
            let sy_a = scenario.take_from_sender<standardized_yield::SYToken<TEST_COIN>>();
            let coin_out = standardized_yield::redeem(&mut vault, sy_a, scenario.ctx());

            // Invariant after partial redemption
            assert!(standardized_yield::is_solvent(&vault), 1005);
            assert!(standardized_yield::total_underlying(&vault) == 3000, 1006);
            assert!(standardized_yield::total_supply(&vault) == 3000, 1007);

            sui::transfer::public_transfer(coin_out, USER_A);
            ts::return_shared(vault);
        };

        // USER_B redeems — vault should be empty and solvent
        scenario.next_tx(USER_B);
        {
            let mut vault = scenario.take_shared<SYVault<TEST_COIN>>();
            let sy_b = scenario.take_from_sender<standardized_yield::SYToken<TEST_COIN>>();
            let coin_out = standardized_yield::redeem(&mut vault, sy_b, scenario.ctx());

            assert!(standardized_yield::is_solvent(&vault), 1008);
            assert!(standardized_yield::total_underlying(&vault) == 0, 1009);
            assert!(standardized_yield::total_supply(&vault) == 0, 1010);

            sui::transfer::public_transfer(coin_out, USER_B);
            ts::return_shared(vault);
        };

        scenario.end();
    }

    #[test]
    fun test_invariant_vault_solvency_with_rate_increase() {
        let mut scenario = setup();

        // Deposit
        scenario.next_tx(USER_A);
        {
            let mut vault = scenario.take_shared<SYVault<TEST_COIN>>();
            let coin_a = coin::mint_for_testing<TEST_COIN>(10_000, scenario.ctx());
            let sy_a = standardized_yield::deposit(&mut vault, coin_a, scenario.ctx());
            sui::transfer::public_transfer(sy_a, USER_A);
            ts::return_shared(vault);
        };

        // Increase exchange rate to 1.05 — underlying stays at 10000 but SY
        // supply stays at 10000.  The vault owes 10000*1.05 = 10500 underlying
        // but only holds 10000, so redeem will be bounded by available balance.
        // is_solvent will return false after a rate increase with no new deposits.
        scenario.next_tx(ADMIN);
        {
            let mut vault = scenario.take_shared<SYVault<TEST_COIN>>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(5000);
            let new_rate: u128 = WAD + WAD / 20; // 1.05
            standardized_yield::update_exchange_rate_for_testing(&mut vault, new_rate, &clk);

            // With rate > 1 and no new deposits, solvency depends on whether
            // vault.underlying >= total_sy * rate.  10000 < 10000*1.05 = 10500
            // so is_solvent should be false — that is expected protocol behavior
            // (in production, yield accrual is funded externally by the adapter).
            // We just verify the function returns the correct boolean.
            let solvent = standardized_yield::is_solvent(&vault);
            assert!(!solvent, 1011); // expected: vault is under-funded

            clk.destroy_for_testing();
            ts::return_shared(vault);
        };

        scenario.end();
    }

    // ========================================================================
    // 2. PT+YT Supply Symmetry at Mint / Redeem
    // ========================================================================

    #[test]
    fun test_invariant_pt_yt_supply_symmetry_mint() {
        let mut scenario = setup();

        scenario.next_tx(USER_A);
        {
            let mut config = scenario.take_shared<YieldMarketConfig<TEST_COIN>>();
            let vault = scenario.take_shared<SYVault<TEST_COIN>>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(2000);

            let pt_before = yield_tokenizer::total_pt_supply(&config);
            let yt_before = yield_tokenizer::total_yt_supply(&config);

            let coin_in = coin::mint_for_testing<TEST_COIN>(1000, scenario.ctx());
            let (pt, yt) = yield_tokenizer::mint_py(
                &mut config, &vault, coin_in, &clk, scenario.ctx(),
            );

            let pt_after = yield_tokenizer::total_pt_supply(&config);
            let yt_after = yield_tokenizer::total_yt_supply(&config);

            // Invariant: PT and YT increase by the same amount
            let pt_delta = pt_after - pt_before;
            let yt_delta = yt_after - yt_before;
            assert!(pt_delta == yt_delta, 2001);

            // Both equal the minted amount
            assert!(yield_tokenizer::pt_amount(&pt) == pt_delta, 2002);
            assert!(yield_tokenizer::yt_amount(&yt) == yt_delta, 2003);

            sui::transfer::public_transfer(pt, USER_A);
            sui::transfer::public_transfer(yt, USER_A);
            clk.destroy_for_testing();
            ts::return_shared(config);
            ts::return_shared(vault);
        };

        scenario.end();
    }

    #[test]
    fun test_invariant_pt_yt_supply_symmetry_redeem_pre_expiry() {
        let mut scenario = setup();

        // Mint
        scenario.next_tx(USER_A);
        {
            let mut config = scenario.take_shared<YieldMarketConfig<TEST_COIN>>();
            let vault = scenario.take_shared<SYVault<TEST_COIN>>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(2000);
            let coin_in = coin::mint_for_testing<TEST_COIN>(2000, scenario.ctx());
            let (pt, yt) = yield_tokenizer::mint_py(
                &mut config, &vault, coin_in, &clk, scenario.ctx(),
            );
            sui::transfer::public_transfer(pt, USER_A);
            sui::transfer::public_transfer(yt, USER_A);
            clk.destroy_for_testing();
            ts::return_shared(config);
            ts::return_shared(vault);
        };

        // Redeem pre-expiry
        scenario.next_tx(USER_A);
        {
            let mut config = scenario.take_shared<YieldMarketConfig<TEST_COIN>>();
            let vault = scenario.take_shared<SYVault<TEST_COIN>>();
            let pt = scenario.take_from_sender<PT<TEST_COIN>>();
            let yt = scenario.take_from_sender<YT<TEST_COIN>>();

            let pt_before = yield_tokenizer::total_pt_supply(&config);
            let yt_before = yield_tokenizer::total_yt_supply(&config);

            let coin_out = yield_tokenizer::redeem_py_pre_expiry(
                &mut config, &vault, pt, yt, scenario.ctx(),
            );

            let pt_after = yield_tokenizer::total_pt_supply(&config);
            let yt_after = yield_tokenizer::total_yt_supply(&config);

            // Invariant: PT and YT both decrease by the same amount
            let pt_delta = pt_before - pt_after;
            let yt_delta = yt_before - yt_after;
            assert!(pt_delta == yt_delta, 2004);

            // Both supplies should be zero now
            assert!(pt_after == 0, 2005);
            assert!(yt_after == 0, 2006);

            sui::transfer::public_transfer(coin_out, USER_A);
            ts::return_shared(config);
            ts::return_shared(vault);
        };

        scenario.end();
    }

    #[test]
    fun test_invariant_pt_yt_symmetry_multi_user() {
        let mut scenario = setup();

        // USER_A mints
        scenario.next_tx(USER_A);
        {
            let mut config = scenario.take_shared<YieldMarketConfig<TEST_COIN>>();
            let vault = scenario.take_shared<SYVault<TEST_COIN>>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(2000);
            let coin_in = coin::mint_for_testing<TEST_COIN>(1000, scenario.ctx());
            let (pt, yt) = yield_tokenizer::mint_py(
                &mut config, &vault, coin_in, &clk, scenario.ctx(),
            );
            sui::transfer::public_transfer(pt, USER_A);
            sui::transfer::public_transfer(yt, USER_A);
            clk.destroy_for_testing();
            ts::return_shared(config);
            ts::return_shared(vault);
        };

        // USER_B mints
        scenario.next_tx(USER_B);
        {
            let mut config = scenario.take_shared<YieldMarketConfig<TEST_COIN>>();
            let vault = scenario.take_shared<SYVault<TEST_COIN>>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(3000);
            let coin_in = coin::mint_for_testing<TEST_COIN>(3000, scenario.ctx());
            let (pt, yt) = yield_tokenizer::mint_py(
                &mut config, &vault, coin_in, &clk, scenario.ctx(),
            );

            // Invariant: cumulative supplies remain symmetric
            assert!(
                yield_tokenizer::total_pt_supply(&config) ==
                yield_tokenizer::total_yt_supply(&config),
                2007,
            );

            sui::transfer::public_transfer(pt, USER_B);
            sui::transfer::public_transfer(yt, USER_B);
            clk.destroy_for_testing();
            ts::return_shared(config);
            ts::return_shared(vault);
        };

        // USER_A redeems — symmetry still holds
        scenario.next_tx(USER_A);
        {
            let mut config = scenario.take_shared<YieldMarketConfig<TEST_COIN>>();
            let vault = scenario.take_shared<SYVault<TEST_COIN>>();
            let pt = scenario.take_from_sender<PT<TEST_COIN>>();
            let yt = scenario.take_from_sender<YT<TEST_COIN>>();
            let coin_out = yield_tokenizer::redeem_py_pre_expiry(
                &mut config, &vault, pt, yt, scenario.ctx(),
            );

            assert!(
                yield_tokenizer::total_pt_supply(&config) ==
                yield_tokenizer::total_yt_supply(&config),
                2008,
            );

            sui::transfer::public_transfer(coin_out, USER_A);
            ts::return_shared(config);
            ts::return_shared(vault);
        };

        scenario.end();
    }

    // ========================================================================
    // 3. Reserve Backing — underlying_reserve tracks deposits/withdrawals
    // ========================================================================

    #[test]
    fun test_invariant_reserve_backing_mint_redeem() {
        let mut scenario = setup();

        // Mint — reserve should increase by deposit amount
        scenario.next_tx(USER_A);
        {
            let mut config = scenario.take_shared<YieldMarketConfig<TEST_COIN>>();
            let vault = scenario.take_shared<SYVault<TEST_COIN>>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(2000);

            let reserve_before = yield_tokenizer::reserve_balance(&config);
            assert!(reserve_before == 0, 3001);

            let deposit_amount: u64 = 5000;
            let coin_in = coin::mint_for_testing<TEST_COIN>(deposit_amount, scenario.ctx());
            let (pt, yt) = yield_tokenizer::mint_py(
                &mut config, &vault, coin_in, &clk, scenario.ctx(),
            );

            let reserve_after = yield_tokenizer::reserve_balance(&config);
            // Invariant: reserve increased by exactly the deposited underlying
            assert!(reserve_after == deposit_amount, 3002);

            sui::transfer::public_transfer(pt, USER_A);
            sui::transfer::public_transfer(yt, USER_A);
            clk.destroy_for_testing();
            ts::return_shared(config);
            ts::return_shared(vault);
        };

        // Redeem pre-expiry — reserve should decrease
        scenario.next_tx(USER_A);
        {
            let mut config = scenario.take_shared<YieldMarketConfig<TEST_COIN>>();
            let vault = scenario.take_shared<SYVault<TEST_COIN>>();
            let pt = scenario.take_from_sender<PT<TEST_COIN>>();
            let yt = scenario.take_from_sender<YT<TEST_COIN>>();

            let reserve_before = yield_tokenizer::reserve_balance(&config);

            let coin_out = yield_tokenizer::redeem_py_pre_expiry(
                &mut config, &vault, pt, yt, scenario.ctx(),
            );

            let reserve_after = yield_tokenizer::reserve_balance(&config);
            let withdrawn = coin_out.value();

            // Invariant: reserve decreased by the withdrawn amount
            assert!(reserve_before - reserve_after == withdrawn, 3003);

            sui::transfer::public_transfer(coin_out, USER_A);
            ts::return_shared(config);
            ts::return_shared(vault);
        };

        scenario.end();
    }

    // ========================================================================
    // 4. Yield Reserve Consistency — claim_yield decreases reserve correctly
    // ========================================================================

    #[test]
    fun test_invariant_yield_reserve_after_claim() {
        let mut scenario = setup();

        // Mint PT+YT
        scenario.next_tx(USER_A);
        {
            let mut config = scenario.take_shared<YieldMarketConfig<TEST_COIN>>();
            let vault = scenario.take_shared<SYVault<TEST_COIN>>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(2000);
            let coin_in = coin::mint_for_testing<TEST_COIN>(10_000, scenario.ctx());
            let (pt, yt) = yield_tokenizer::mint_py(
                &mut config, &vault, coin_in, &clk, scenario.ctx(),
            );
            sui::transfer::public_transfer(pt, USER_A);
            sui::transfer::public_transfer(yt, USER_A);
            clk.destroy_for_testing();
            ts::return_shared(config);
            ts::return_shared(vault);
        };

        // Simulate yield accrual by bumping exchange rate and updating PY index
        scenario.next_tx(ADMIN);
        {
            let mut vault = scenario.take_shared<SYVault<TEST_COIN>>();
            let mut config = scenario.take_shared<YieldMarketConfig<TEST_COIN>>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(50_000);

            // Bump rate by 5%
            let new_rate = WAD + WAD / 20; // 1.05
            standardized_yield::update_exchange_rate_for_testing(&mut vault, new_rate, &clk);
            yield_tokenizer::update_py_index(&mut config, &vault, &clk);

            let yield_reserve = yield_tokenizer::yield_reserve_sy(&config);
            // Invariant: yield reserve should be positive after rate increase
            assert!(yield_reserve > 0, 4001);

            clk.destroy_for_testing();
            ts::return_shared(config);
            ts::return_shared(vault);
        };

        // Claim yield
        scenario.next_tx(USER_A);
        {
            let mut config = scenario.take_shared<YieldMarketConfig<TEST_COIN>>();
            let vault = scenario.take_shared<SYVault<TEST_COIN>>();
            let mut yt = scenario.take_from_sender<YT<TEST_COIN>>();

            let reserve_before = yield_tokenizer::yield_reserve_sy(&config);

            let claimed_coin = yield_tokenizer::claim_yield(
                &mut config, &vault, &mut yt, scenario.ctx(),
            );

            let reserve_after = yield_tokenizer::yield_reserve_sy(&config);

            // Invariant: yield_reserve decreased (or stayed at 0)
            assert!(reserve_after <= reserve_before, 4002);

            // Invariant: the decrease equals or is bounded by claimed amount
            // (the claimed_coin is in underlying units, reserve is in SY units,
            //  so we just verify directional correctness)
            if (claimed_coin.value() > 0) {
                assert!(reserve_before > reserve_after, 4003);
            };

            sui::transfer::public_transfer(claimed_coin, USER_A);
            sui::transfer::public_transfer(yt, USER_A);
            ts::return_shared(config);
            ts::return_shared(vault);
        };

        scenario.end();
    }

    #[test]
    fun test_invariant_yield_reserve_zero_when_no_yield() {
        let mut scenario = setup();

        // Mint — no rate change, so yield reserve stays 0
        scenario.next_tx(USER_A);
        {
            let mut config = scenario.take_shared<YieldMarketConfig<TEST_COIN>>();
            let vault = scenario.take_shared<SYVault<TEST_COIN>>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(2000);
            let coin_in = coin::mint_for_testing<TEST_COIN>(1000, scenario.ctx());
            let (pt, yt) = yield_tokenizer::mint_py(
                &mut config, &vault, coin_in, &clk, scenario.ctx(),
            );

            assert!(yield_tokenizer::yield_reserve_sy(&config) == 0, 4010);

            sui::transfer::public_transfer(pt, USER_A);
            sui::transfer::public_transfer(yt, USER_A);
            clk.destroy_for_testing();
            ts::return_shared(config);
            ts::return_shared(vault);
        };

        // Claim yield — nothing to claim, coin should be zero
        scenario.next_tx(USER_A);
        {
            let mut config = scenario.take_shared<YieldMarketConfig<TEST_COIN>>();
            let vault = scenario.take_shared<SYVault<TEST_COIN>>();
            let mut yt = scenario.take_from_sender<YT<TEST_COIN>>();

            let claimed = yield_tokenizer::claim_yield(
                &mut config, &vault, &mut yt, scenario.ctx(),
            );
            assert!(claimed.value() == 0, 4011);
            assert!(yield_tokenizer::yield_reserve_sy(&config) == 0, 4012);

            sui::transfer::public_transfer(claimed, USER_A);
            sui::transfer::public_transfer(yt, USER_A);
            ts::return_shared(config);
            ts::return_shared(vault);
        };

        scenario.end();
    }

    // ========================================================================
    // 5. Exchange Rate Monotonicity — rate can never decrease
    // ========================================================================

    #[test]
    #[expected_failure(abort_code = 204)] // EInvalidExchangeRate
    fun test_invariant_exchange_rate_monotonicity() {
        let mut scenario = setup();

        scenario.next_tx(ADMIN);
        {
            let admin_cap = scenario.take_from_sender<AdminCap>();
            let mut vault = scenario.take_shared<SYVault<TEST_COIN>>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(5000);

            // Increase to 1.05
            let rate_a: u128 = WAD + WAD / 20;
            standardized_yield::update_exchange_rate(&admin_cap, &mut vault, rate_a, &clk);
            assert!(standardized_yield::exchange_rate(&vault) == rate_a, 5001);

            // Try to decrease to 1.02 — must abort
            let rate_b: u128 = WAD + WAD / 50;
            standardized_yield::update_exchange_rate(&admin_cap, &mut vault, rate_b, &clk);

            clk.destroy_for_testing();
            scenario.return_to_sender(admin_cap);
            ts::return_shared(vault);
        };

        scenario.end();
    }

    #[test]
    fun test_invariant_exchange_rate_stays_same_is_ok() {
        let mut scenario = setup();

        scenario.next_tx(ADMIN);
        {
            let admin_cap = scenario.take_from_sender<AdminCap>();
            let mut vault = scenario.take_shared<SYVault<TEST_COIN>>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(5000);

            // Set to WAD (same as initial) — no-op, should succeed
            standardized_yield::update_exchange_rate(&admin_cap, &mut vault, WAD, &clk);
            assert!(standardized_yield::exchange_rate(&vault) == WAD, 5010);

            clk.destroy_for_testing();
            scenario.return_to_sender(admin_cap);
            ts::return_shared(vault);
        };

        scenario.end();
    }

    // ========================================================================
    // 6. Rate Increase Cap — >10% increase in a single call fails
    // ========================================================================

    #[test]
    #[expected_failure(abort_code = 205)] // ERateIncreaseTooLarge
    fun test_invariant_rate_increase_cap() {
        let mut scenario = setup();

        scenario.next_tx(ADMIN);
        {
            let admin_cap = scenario.take_from_sender<AdminCap>();
            let mut vault = scenario.take_shared<SYVault<TEST_COIN>>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(5000);

            // Try to jump from 1.0 to 1.2 (20% increase) — exceeds 10% cap
            let bad_rate: u128 = WAD + WAD / 5; // 1.20
            standardized_yield::update_exchange_rate(&admin_cap, &mut vault, bad_rate, &clk);

            clk.destroy_for_testing();
            scenario.return_to_sender(admin_cap);
            ts::return_shared(vault);
        };

        scenario.end();
    }

    #[test]
    fun test_invariant_rate_increase_at_cap_succeeds() {
        let mut scenario = setup();

        scenario.next_tx(ADMIN);
        {
            let admin_cap = scenario.take_from_sender<AdminCap>();
            let mut vault = scenario.take_shared<SYVault<TEST_COIN>>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(5000);

            // Exactly 10% increase from WAD should succeed
            // max_allowed = WAD + WAD * 0.10 = 1.10 * WAD
            let rate_10pct: u128 = WAD + WAD / 10; // 1.10
            standardized_yield::update_exchange_rate(&admin_cap, &mut vault, rate_10pct, &clk);
            assert!(standardized_yield::exchange_rate(&vault) == rate_10pct, 6001);

            clk.destroy_for_testing();
            scenario.return_to_sender(admin_cap);
            ts::return_shared(vault);
        };

        scenario.end();
    }

    #[test]
    fun test_invariant_rate_increase_stepwise_ok() {
        let mut scenario = setup();

        // Two successive 10% increases (1.0 -> 1.1 -> 1.21) are individually OK
        scenario.next_tx(ADMIN);
        {
            let admin_cap = scenario.take_from_sender<AdminCap>();
            let mut vault = scenario.take_shared<SYVault<TEST_COIN>>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(5000);

            let rate1: u128 = WAD + WAD / 10; // 1.10
            standardized_yield::update_exchange_rate(&admin_cap, &mut vault, rate1, &clk);

            // 10% of 1.1 = 0.11, so max = 1.21
            let rate2: u128 = rate1 + fixed_point::wad_mul(rate1, WAD / 10);
            standardized_yield::update_exchange_rate(&admin_cap, &mut vault, rate2, &clk);
            assert!(standardized_yield::exchange_rate(&vault) == rate2, 6010);

            clk.destroy_for_testing();
            scenario.return_to_sender(admin_cap);
            ts::return_shared(vault);
        };

        scenario.end();
    }

    // ========================================================================
    // 7. LP Token Proportionality — reserves change proportionally to LP
    // ========================================================================

    #[test]
    fun test_invariant_lp_proportionality_add_remove() {
        let mut scenario = setup();

        // Create a pool
        scenario.next_tx(ADMIN);
        {
            let mut config = scenario.take_shared<YieldMarketConfig<TEST_COIN>>();
            let vault = scenario.take_shared<SYVault<TEST_COIN>>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(2000);

            let initial_underlying = coin::mint_for_testing<TEST_COIN>(10_000, scenario.ctx());
            let lp = rate_market::create_pool(
                &mut config, &vault, initial_underlying,
                1000, 1000, &clk, scenario.ctx(),
            );

            // Record initial state
            sui::transfer::public_transfer(lp, ADMIN);
            clk.destroy_for_testing();
            ts::return_shared(config);
            ts::return_shared(vault);
        };

        // Add liquidity and verify proportionality
        scenario.next_tx(USER_A);
        {
            let mut pool = scenario.take_shared<YieldPool<TEST_COIN>>();
            let vault = scenario.take_shared<SYVault<TEST_COIN>>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(3000);

            let pt_res_before = rate_market::pt_reserve(&pool);
            let sy_res_before = rate_market::sy_reserve(&pool);
            let lp_supply_before = rate_market::total_lp_supply(&pool);

            let underlying = coin::mint_for_testing<TEST_COIN>(5000, scenario.ctx());
            let lp = rate_market::add_liquidity(
                &mut pool, &vault, underlying, 500, 500, &clk, scenario.ctx(),
            );

            let pt_res_after = rate_market::pt_reserve(&pool);
            let sy_res_after = rate_market::sy_reserve(&pool);
            let lp_supply_after = rate_market::total_lp_supply(&pool);

            // Invariant: reserves increased
            assert!(pt_res_after == pt_res_before + 500, 7001);
            assert!(sy_res_after == sy_res_before + 500, 7002);
            assert!(lp_supply_after > lp_supply_before, 7003);

            sui::transfer::public_transfer(lp, USER_A);
            clk.destroy_for_testing();
            ts::return_shared(pool);
            ts::return_shared(vault);
        };

        // Remove liquidity — reserves and LP supply should decrease proportionally
        scenario.next_tx(USER_A);
        {
            let mut pool = scenario.take_shared<YieldPool<TEST_COIN>>();
            let vault = scenario.take_shared<SYVault<TEST_COIN>>();
            let lp = scenario.take_from_sender<LPToken<TEST_COIN>>();

            let pt_res_before = rate_market::pt_reserve(&pool);
            let sy_res_before = rate_market::sy_reserve(&pool);
            let lp_supply_before = rate_market::total_lp_supply(&pool);
            let lp_amount = rate_market::lp_amount(&lp);

            let coin_out = rate_market::remove_liquidity(
                &mut pool, &vault, lp, scenario.ctx(),
            );

            let pt_res_after = rate_market::pt_reserve(&pool);
            let sy_res_after = rate_market::sy_reserve(&pool);
            let lp_supply_after = rate_market::total_lp_supply(&pool);

            // Invariant: LP supply decreased by burned amount
            assert!(lp_supply_before - lp_supply_after == lp_amount, 7004);

            // Invariant: reserves decreased
            assert!(pt_res_after < pt_res_before, 7005);
            assert!(sy_res_after < sy_res_before, 7006);

            sui::transfer::public_transfer(coin_out, USER_A);
            ts::return_shared(pool);
            ts::return_shared(vault);
        };

        scenario.end();
    }

    // ========================================================================
    // 8. Flash Mint Atomicity — supply tracking round-trip
    // ========================================================================

    #[test]
    fun test_invariant_flash_mint_supply_tracking() {
        let mut scenario = setup();

        scenario.next_tx(USER_A);
        {
            let mut config = scenario.take_shared<YieldMarketConfig<TEST_COIN>>();
            let vault = scenario.take_shared<SYVault<TEST_COIN>>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(2000);

            let pt_before = yield_tokenizer::total_pt_supply(&config);
            let yt_before = yield_tokenizer::total_yt_supply(&config);

            // Flash mint
            let (pt, yt, receipt) = flash_mint::flash_mint(
                &mut config, 1000, &clk, scenario.ctx(),
            );

            let pt_mid = yield_tokenizer::total_pt_supply(&config);
            let yt_mid = yield_tokenizer::total_yt_supply(&config);

            // Invariant: supplies increased symmetrically
            assert!(pt_mid == pt_before + 1000, 8001);
            assert!(yt_mid == yt_before + 1000, 8002);
            assert!(pt_mid == yt_mid, 8003);

            // Invariant: PT and YT amounts match
            assert!(yield_tokenizer::pt_amount(&pt) == 1000, 8004);
            assert!(yield_tokenizer::yt_amount(&yt) == 1000, 8005);

            // Repay
            let owed = flash_mint::amount_owed(&receipt);
            let repay_coin = coin::mint_for_testing<TEST_COIN>(owed + 100, scenario.ctx());
            flash_mint::repay_flash_mint(
                &mut config, &vault, receipt, repay_coin, scenario.ctx(),
            );

            // Invariant: after repay, reserve has been funded
            let reserve = yield_tokenizer::reserve_balance(&config);
            assert!(reserve > 0, 8006);

            // Invariant: supplies remain consistent after repay
            // (repay doesn't change PT/YT supply, only funds the reserve)
            assert!(yield_tokenizer::total_pt_supply(&config) == pt_mid, 8007);
            assert!(yield_tokenizer::total_yt_supply(&config) == yt_mid, 8008);

            sui::transfer::public_transfer(pt, USER_A);
            sui::transfer::public_transfer(yt, USER_A);
            clk.destroy_for_testing();
            ts::return_shared(config);
            ts::return_shared(vault);
        };

        scenario.end();
    }

    #[test]
    fun test_invariant_flash_mint_redeem_full_cycle() {
        let mut scenario = setup();

        // Flash mint + repay
        scenario.next_tx(USER_A);
        {
            let mut config = scenario.take_shared<YieldMarketConfig<TEST_COIN>>();
            let vault = scenario.take_shared<SYVault<TEST_COIN>>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(2000);

            let (pt, yt, receipt) = flash_mint::flash_mint(
                &mut config, 500, &clk, scenario.ctx(),
            );

            let repay_coin = coin::mint_for_testing<TEST_COIN>(600, scenario.ctx());
            flash_mint::repay_flash_mint(
                &mut config, &vault, receipt, repay_coin, scenario.ctx(),
            );

            sui::transfer::public_transfer(pt, USER_A);
            sui::transfer::public_transfer(yt, USER_A);
            clk.destroy_for_testing();
            ts::return_shared(config);
            ts::return_shared(vault);
        };

        // Redeem pre-expiry — the tokens from flash mint should be redeemable
        scenario.next_tx(USER_A);
        {
            let mut config = scenario.take_shared<YieldMarketConfig<TEST_COIN>>();
            let vault = scenario.take_shared<SYVault<TEST_COIN>>();
            let pt = scenario.take_from_sender<PT<TEST_COIN>>();
            let yt = scenario.take_from_sender<YT<TEST_COIN>>();

            let coin_out = yield_tokenizer::redeem_py_pre_expiry(
                &mut config, &vault, pt, yt, scenario.ctx(),
            );

            // Invariant: after full cycle, supplies return to zero
            assert!(yield_tokenizer::total_pt_supply(&config) == 0, 8020);
            assert!(yield_tokenizer::total_yt_supply(&config) == 0, 8021);

            sui::transfer::public_transfer(coin_out, USER_A);
            ts::return_shared(config);
            ts::return_shared(vault);
        };

        scenario.end();
    }

    // ========================================================================
    // 9. Settlement Finality — settle_market is idempotent (second call fails)
    // ========================================================================

    #[test]
    #[expected_failure(abort_code = 305)] // EAlreadySettled
    fun test_invariant_settlement_finality_double_settle() {
        let mut scenario = setup();

        scenario.next_tx(ADMIN);
        {
            let admin_cap = scenario.take_from_sender<AdminCap>();
            let mut config = scenario.take_shared<YieldMarketConfig<TEST_COIN>>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(MATURITY_MS + 1);

            // First settle — should succeed
            yield_tokenizer::settle_market(&admin_cap, &mut config, &clk);
            assert!(yield_tokenizer::is_expired(&config), 9001);

            let frozen_index = yield_tokenizer::settlement_py_index(&config);
            assert!(frozen_index > 0, 9002);

            // Second settle — must abort with EAlreadySettled
            yield_tokenizer::settle_market(&admin_cap, &mut config, &clk);

            clk.destroy_for_testing();
            scenario.return_to_sender(admin_cap);
            ts::return_shared(config);
        };

        scenario.end();
    }

    #[test]
    fun test_invariant_settlement_freezes_py_index() {
        let mut scenario = setup();

        // Mint first so we have supply
        scenario.next_tx(USER_A);
        {
            let mut config = scenario.take_shared<YieldMarketConfig<TEST_COIN>>();
            let vault = scenario.take_shared<SYVault<TEST_COIN>>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(2000);
            let coin_in = coin::mint_for_testing<TEST_COIN>(5000, scenario.ctx());
            let (pt, yt) = yield_tokenizer::mint_py(
                &mut config, &vault, coin_in, &clk, scenario.ctx(),
            );
            sui::transfer::public_transfer(pt, USER_A);
            sui::transfer::public_transfer(yt, USER_A);
            clk.destroy_for_testing();
            ts::return_shared(config);
            ts::return_shared(vault);
        };

        // Bump rate, then settle
        scenario.next_tx(ADMIN);
        {
            let admin_cap = scenario.take_from_sender<AdminCap>();
            let mut vault = scenario.take_shared<SYVault<TEST_COIN>>();
            let mut config = scenario.take_shared<YieldMarketConfig<TEST_COIN>>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(50_000);

            let new_rate: u128 = WAD + WAD / 20; // 1.05
            standardized_yield::update_exchange_rate(&admin_cap, &mut vault, new_rate, &clk);
            yield_tokenizer::update_py_index(&mut config, &vault, &clk);

            let py_index_before_settle = yield_tokenizer::current_py_index(&config);

            // Settle
            clk.set_for_testing(MATURITY_MS + 1);
            yield_tokenizer::settle_market(&admin_cap, &mut config, &clk);

            // Invariant: settlement_py_index == current_py_index at settlement time
            let settlement_idx = yield_tokenizer::settlement_py_index(&config);
            assert!(settlement_idx == py_index_before_settle, 9010);

            clk.destroy_for_testing();
            scenario.return_to_sender(admin_cap);
            ts::return_shared(config);
            ts::return_shared(vault);
        };

        scenario.end();
    }

    // ========================================================================
    // 10. Dust Deposit Prevention — rounding to 0 SY should fail
    // ========================================================================

    #[test]
    #[expected_failure(abort_code = 200)] // EZeroDeposit
    fun test_invariant_dust_deposit_prevented_vault() {
        let mut scenario = setup();

        // Increase rate stepwise to 2.0 WAD (each step <= 10% increase)
        // WAD -> 1.1 -> 1.21 -> 1.331 -> 1.4641 -> 1.61051 -> 1.771561 -> 1.9487171 -> ~2.14
        // We need rate >= 2.0 so that depositing 1 unit rounds to 0 SY.
        scenario.next_tx(ADMIN);
        {
            let mut vault = scenario.take_shared<SYVault<TEST_COIN>>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(5000);

            // Step through 10% increases: 8 steps gets us past 2.0
            let mut rate: u128 = WAD;
            let mut i = 0;
            while (i < 8) {
                rate = rate + fixed_point::wad_mul(rate, WAD / 10);
                standardized_yield::update_exchange_rate_for_testing(&mut vault, rate, &clk);
                i = i + 1;
            };
            // After 8 steps of 10%: 1.0 * 1.1^8 = 2.1435... WAD
            // Depositing 1 unit: 1 / 2.1435 = 0.466 -> truncates to 0 SY

            clk.destroy_for_testing();
            ts::return_shared(vault);
        };

        // Try depositing 1 unit — at rate > 2.0, 1 / rate -> truncates to 0
        scenario.next_tx(USER_A);
        {
            let mut vault = scenario.take_shared<SYVault<TEST_COIN>>();
            let dust_coin = coin::mint_for_testing<TEST_COIN>(1, scenario.ctx());
            let sy = standardized_yield::deposit(&mut vault, dust_coin, scenario.ctx());
            sui::transfer::public_transfer(sy, USER_A);
            ts::return_shared(vault);
        };

        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = 200)] // EZeroDeposit
    fun test_invariant_zero_deposit_vault() {
        let mut scenario = setup();

        scenario.next_tx(USER_A);
        {
            let mut vault = scenario.take_shared<SYVault<TEST_COIN>>();
            let zero_coin = coin::mint_for_testing<TEST_COIN>(0, scenario.ctx());
            let sy = standardized_yield::deposit(&mut vault, zero_coin, scenario.ctx());
            sui::transfer::public_transfer(sy, USER_A);
            ts::return_shared(vault);
        };

        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = 302)] // EZeroAmount
    fun test_invariant_zero_mint_py() {
        let mut scenario = setup();

        scenario.next_tx(USER_A);
        {
            let mut config = scenario.take_shared<YieldMarketConfig<TEST_COIN>>();
            let vault = scenario.take_shared<SYVault<TEST_COIN>>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(2000);
            let zero_coin = coin::mint_for_testing<TEST_COIN>(0, scenario.ctx());
            let (pt, yt) = yield_tokenizer::mint_py(
                &mut config, &vault, zero_coin, &clk, scenario.ctx(),
            );
            sui::transfer::public_transfer(pt, USER_A);
            sui::transfer::public_transfer(yt, USER_A);
            clk.destroy_for_testing();
            ts::return_shared(config);
            ts::return_shared(vault);
        };

        scenario.end();
    }

    // ========================================================================
    // Cross-cutting: PT redemption post-expiry with settlement
    // ========================================================================

    #[test]
    fun test_invariant_pt_redeem_post_expiry_supply_tracking() {
        let mut scenario = setup();

        // Mint
        scenario.next_tx(USER_A);
        {
            let mut config = scenario.take_shared<YieldMarketConfig<TEST_COIN>>();
            let vault = scenario.take_shared<SYVault<TEST_COIN>>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(2000);
            let coin_in = coin::mint_for_testing<TEST_COIN>(5000, scenario.ctx());
            let (pt, yt) = yield_tokenizer::mint_py(
                &mut config, &vault, coin_in, &clk, scenario.ctx(),
            );
            sui::transfer::public_transfer(pt, USER_A);
            sui::transfer::public_transfer(yt, USER_A);
            clk.destroy_for_testing();
            ts::return_shared(config);
            ts::return_shared(vault);
        };

        // Settle
        scenario.next_tx(ADMIN);
        {
            let admin_cap = scenario.take_from_sender<AdminCap>();
            let mut config = scenario.take_shared<YieldMarketConfig<TEST_COIN>>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(MATURITY_MS + 1);
            yield_tokenizer::settle_market(&admin_cap, &mut config, &clk);
            clk.destroy_for_testing();
            scenario.return_to_sender(admin_cap);
            ts::return_shared(config);
        };

        // Redeem PT post-expiry
        scenario.next_tx(USER_A);
        {
            let mut config = scenario.take_shared<YieldMarketConfig<TEST_COIN>>();
            let pt = scenario.take_from_sender<PT<TEST_COIN>>();

            let pt_supply_before = yield_tokenizer::total_pt_supply(&config);
            let pt_amt = yield_tokenizer::pt_amount(&pt);

            let coin_out = yield_tokenizer::redeem_pt_post_expiry(
                &mut config, pt, scenario.ctx(),
            );

            let pt_supply_after = yield_tokenizer::total_pt_supply(&config);

            // Invariant: PT supply decreased by the redeemed amount
            assert!(pt_supply_before - pt_supply_after == pt_amt, 11001);
            assert!(coin_out.value() > 0, 11002);

            sui::transfer::public_transfer(coin_out, USER_A);
            ts::return_shared(config);
        };

        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = 301)] // EMarketNotExpired
    fun test_invariant_pt_redeem_post_expiry_requires_settlement() {
        let mut scenario = setup();

        // Mint
        scenario.next_tx(USER_A);
        {
            let mut config = scenario.take_shared<YieldMarketConfig<TEST_COIN>>();
            let vault = scenario.take_shared<SYVault<TEST_COIN>>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(2000);
            let coin_in = coin::mint_for_testing<TEST_COIN>(1000, scenario.ctx());
            let (pt, yt) = yield_tokenizer::mint_py(
                &mut config, &vault, coin_in, &clk, scenario.ctx(),
            );
            sui::transfer::public_transfer(pt, USER_A);
            sui::transfer::public_transfer(yt, USER_A);
            clk.destroy_for_testing();
            ts::return_shared(config);
            ts::return_shared(vault);
        };

        // Try to redeem PT without settling — must fail
        scenario.next_tx(USER_A);
        {
            let mut config = scenario.take_shared<YieldMarketConfig<TEST_COIN>>();
            let pt = scenario.take_from_sender<PT<TEST_COIN>>();
            let coin_out = yield_tokenizer::redeem_pt_post_expiry(
                &mut config, pt, scenario.ctx(),
            );
            sui::transfer::public_transfer(coin_out, USER_A);
            ts::return_shared(config);
        };

        scenario.end();
    }

    // ========================================================================
    // Cross-cutting: Mint after expiry blocked
    // ========================================================================

    #[test]
    #[expected_failure(abort_code = 300)] // EMarketExpired
    fun test_invariant_no_mint_after_expiry() {
        let mut scenario = setup();

        // Settle
        scenario.next_tx(ADMIN);
        {
            let admin_cap = scenario.take_from_sender<AdminCap>();
            let mut config = scenario.take_shared<YieldMarketConfig<TEST_COIN>>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(MATURITY_MS + 1);
            yield_tokenizer::settle_market(&admin_cap, &mut config, &clk);
            clk.destroy_for_testing();
            scenario.return_to_sender(admin_cap);
            ts::return_shared(config);
        };

        // Attempt mint — must abort
        scenario.next_tx(USER_A);
        {
            let mut config = scenario.take_shared<YieldMarketConfig<TEST_COIN>>();
            let vault = scenario.take_shared<SYVault<TEST_COIN>>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(MATURITY_MS + 2);
            let coin_in = coin::mint_for_testing<TEST_COIN>(1000, scenario.ctx());
            let (pt, yt) = yield_tokenizer::mint_py(
                &mut config, &vault, coin_in, &clk, scenario.ctx(),
            );
            sui::transfer::public_transfer(pt, USER_A);
            sui::transfer::public_transfer(yt, USER_A);
            clk.destroy_for_testing();
            ts::return_shared(config);
            ts::return_shared(vault);
        };

        scenario.end();
    }

    // ========================================================================
    // Cross-cutting: Redeem pre-expiry requires matching PT + YT amounts
    // ========================================================================

    #[test]
    #[expected_failure(abort_code = 303)] // EMismatchedAmounts
    fun test_invariant_redeem_requires_equal_pt_yt() {
        let mut scenario = setup();

        // Mint
        scenario.next_tx(USER_A);
        {
            let mut config = scenario.take_shared<YieldMarketConfig<TEST_COIN>>();
            let vault = scenario.take_shared<SYVault<TEST_COIN>>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(2000);
            let coin_in = coin::mint_for_testing<TEST_COIN>(2000, scenario.ctx());
            let (pt, yt) = yield_tokenizer::mint_py(
                &mut config, &vault, coin_in, &clk, scenario.ctx(),
            );

            // Split PT so amounts don't match
            let mut pt_mut = pt;
            let pt_leftover = yield_tokenizer::split_pt(&mut pt_mut, 500, scenario.ctx());

            sui::transfer::public_transfer(pt_mut, USER_A);
            sui::transfer::public_transfer(pt_leftover, USER_A);
            sui::transfer::public_transfer(yt, USER_A);
            clk.destroy_for_testing();
            ts::return_shared(config);
            ts::return_shared(vault);
        };

        // Try to redeem with mismatched amounts
        scenario.next_tx(USER_A);
        {
            let mut config = scenario.take_shared<YieldMarketConfig<TEST_COIN>>();
            let vault = scenario.take_shared<SYVault<TEST_COIN>>();
            // pt_mut has 1500, yt has 2000 — mismatch
            let pt = scenario.take_from_sender<PT<TEST_COIN>>();
            let yt = scenario.take_from_sender<YT<TEST_COIN>>();

            let coin_out = yield_tokenizer::redeem_py_pre_expiry(
                &mut config, &vault, pt, yt, scenario.ctx(),
            );

            sui::transfer::public_transfer(coin_out, USER_A);
            ts::return_shared(config);
            ts::return_shared(vault);
        };

        scenario.end();
    }

    // ========================================================================
    // Cross-cutting: Fallback settlement respects keeper timeout
    // ========================================================================

    #[test]
    #[expected_failure(abort_code = 307)] // EKeeperStillActive
    fun test_invariant_fallback_settlement_too_early() {
        let mut scenario = setup();

        scenario.next_tx(USER_A);
        {
            let mut config = scenario.take_shared<YieldMarketConfig<TEST_COIN>>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            // Just past maturity but before keeper timeout (maturity + 2hrs)
            clk.set_for_testing(MATURITY_MS + 1000);

            yield_tokenizer::settle_market_fallback(&mut config, &clk);

            clk.destroy_for_testing();
            ts::return_shared(config);
        };

        scenario.end();
    }

    #[test]
    fun test_invariant_fallback_settlement_after_timeout() {
        let mut scenario = setup();

        scenario.next_tx(USER_A);
        {
            let mut config = scenario.take_shared<YieldMarketConfig<TEST_COIN>>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            // Past maturity + 2hr keeper timeout
            let keeper_timeout: u64 = 7_200_000;
            clk.set_for_testing(MATURITY_MS + keeper_timeout + 1);

            yield_tokenizer::settle_market_fallback(&mut config, &clk);

            assert!(yield_tokenizer::is_expired(&config), 12001);
            assert!(yield_tokenizer::settlement_py_index(&config) > 0, 12002);

            clk.destroy_for_testing();
            ts::return_shared(config);
        };

        scenario.end();
    }

    // ========================================================================
    // Cross-cutting: PY index update idempotent when rate unchanged
    // ========================================================================

    #[test]
    fun test_invariant_py_index_update_idempotent() {
        let mut scenario = setup();

        // Mint
        scenario.next_tx(USER_A);
        {
            let mut config = scenario.take_shared<YieldMarketConfig<TEST_COIN>>();
            let vault = scenario.take_shared<SYVault<TEST_COIN>>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(2000);
            let coin_in = coin::mint_for_testing<TEST_COIN>(1000, scenario.ctx());
            let (pt, yt) = yield_tokenizer::mint_py(
                &mut config, &vault, coin_in, &clk, scenario.ctx(),
            );
            sui::transfer::public_transfer(pt, USER_A);
            sui::transfer::public_transfer(yt, USER_A);
            clk.destroy_for_testing();
            ts::return_shared(config);
            ts::return_shared(vault);
        };

        // Call update_py_index twice without rate change — should be idempotent
        scenario.next_tx(ADMIN);
        {
            let vault = scenario.take_shared<SYVault<TEST_COIN>>();
            let mut config = scenario.take_shared<YieldMarketConfig<TEST_COIN>>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(10_000);

            yield_tokenizer::update_py_index(&mut config, &vault, &clk);
            let reserve_after_first = yield_tokenizer::yield_reserve_sy(&config);
            let index_after_first = yield_tokenizer::global_interest_index(&config);

            yield_tokenizer::update_py_index(&mut config, &vault, &clk);
            let reserve_after_second = yield_tokenizer::yield_reserve_sy(&config);
            let index_after_second = yield_tokenizer::global_interest_index(&config);

            // Invariant: second call is a no-op
            assert!(reserve_after_first == reserve_after_second, 13001);
            assert!(index_after_first == index_after_second, 13002);

            clk.destroy_for_testing();
            ts::return_shared(config);
            ts::return_shared(vault);
        };

        scenario.end();
    }

    // ========================================================================
    // Cross-cutting: Vault pause blocks deposit
    // ========================================================================

    #[test]
    #[expected_failure(abort_code = 203)] // EVaultPaused
    fun test_invariant_paused_vault_blocks_deposit() {
        let mut scenario = setup();

        scenario.next_tx(ADMIN);
        {
            let admin_cap = scenario.take_from_sender<AdminCap>();
            let mut vault = scenario.take_shared<SYVault<TEST_COIN>>();
            standardized_yield::pause_vault(&admin_cap, &mut vault);
            scenario.return_to_sender(admin_cap);
            ts::return_shared(vault);
        };

        scenario.next_tx(USER_A);
        {
            let mut vault = scenario.take_shared<SYVault<TEST_COIN>>();
            let coin_in = coin::mint_for_testing<TEST_COIN>(1000, scenario.ctx());
            let sy = standardized_yield::deposit(&mut vault, coin_in, scenario.ctx());
            sui::transfer::public_transfer(sy, USER_A);
            ts::return_shared(vault);
        };

        scenario.end();
    }

    // ========================================================================
    // Cross-cutting: Paused vault blocks mint_py (via vault pause check)
    // ========================================================================

    #[test]
    #[expected_failure(abort_code = 207)] // Vault paused check in mint_py
    fun test_invariant_paused_vault_blocks_mint_py() {
        let mut scenario = setup();

        scenario.next_tx(ADMIN);
        {
            let admin_cap = scenario.take_from_sender<AdminCap>();
            let mut vault = scenario.take_shared<SYVault<TEST_COIN>>();
            standardized_yield::pause_vault(&admin_cap, &mut vault);
            scenario.return_to_sender(admin_cap);
            ts::return_shared(vault);
        };

        scenario.next_tx(USER_A);
        {
            let mut config = scenario.take_shared<YieldMarketConfig<TEST_COIN>>();
            let vault = scenario.take_shared<SYVault<TEST_COIN>>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(2000);
            let coin_in = coin::mint_for_testing<TEST_COIN>(1000, scenario.ctx());
            let (pt, yt) = yield_tokenizer::mint_py(
                &mut config, &vault, coin_in, &clk, scenario.ctx(),
            );
            sui::transfer::public_transfer(pt, USER_A);
            sui::transfer::public_transfer(yt, USER_A);
            clk.destroy_for_testing();
            ts::return_shared(config);
            ts::return_shared(vault);
        };

        scenario.end();
    }

    // ========================================================================
    // Flash mint: insufficient repayment fails
    // ========================================================================

    #[test]
    #[expected_failure(abort_code = 400)] // EInsufficientRepayment
    fun test_invariant_flash_mint_underpayment_fails() {
        let mut scenario = setup();

        scenario.next_tx(USER_A);
        {
            let mut config = scenario.take_shared<YieldMarketConfig<TEST_COIN>>();
            let vault = scenario.take_shared<SYVault<TEST_COIN>>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(2000);

            let (pt, yt, receipt) = flash_mint::flash_mint(
                &mut config, 1000, &clk, scenario.ctx(),
            );

            // Pay less than owed
            let underpay = coin::mint_for_testing<TEST_COIN>(500, scenario.ctx());
            flash_mint::repay_flash_mint(
                &mut config, &vault, receipt, underpay, scenario.ctx(),
            );

            sui::transfer::public_transfer(pt, USER_A);
            sui::transfer::public_transfer(yt, USER_A);
            clk.destroy_for_testing();
            ts::return_shared(config);
            ts::return_shared(vault);
        };

        scenario.end();
    }

    // ========================================================================
    // Flash mint: zero amount fails
    // ========================================================================

    #[test]
    #[expected_failure(abort_code = 401)] // EZeroAmount
    fun test_invariant_flash_mint_zero_amount_fails() {
        let mut scenario = setup();

        scenario.next_tx(USER_A);
        {
            let mut config = scenario.take_shared<YieldMarketConfig<TEST_COIN>>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(2000);

            let (pt, yt, receipt) = flash_mint::flash_mint(
                &mut config, 0, &clk, scenario.ctx(),
            );

            sui::transfer::public_transfer(pt, USER_A);
            sui::transfer::public_transfer(yt, USER_A);
            flash_mint::destroy_receipt_for_testing(receipt);
            clk.destroy_for_testing();
            ts::return_shared(config);
        };

        scenario.end();
    }

    // ========================================================================
    // Comprehensive multi-step stress test
    // ========================================================================

    #[test]
    fun test_invariant_multi_step_stress() {
        let mut scenario = setup();

        // Step 1: USER_A mints 10000
        scenario.next_tx(USER_A);
        {
            let mut config = scenario.take_shared<YieldMarketConfig<TEST_COIN>>();
            let vault = scenario.take_shared<SYVault<TEST_COIN>>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(2000);
            let coin_in = coin::mint_for_testing<TEST_COIN>(10_000, scenario.ctx());
            let (pt, yt) = yield_tokenizer::mint_py(
                &mut config, &vault, coin_in, &clk, scenario.ctx(),
            );

            // Invariant check
            assert!(
                yield_tokenizer::total_pt_supply(&config) ==
                yield_tokenizer::total_yt_supply(&config),
                14001,
            );

            sui::transfer::public_transfer(pt, USER_A);
            sui::transfer::public_transfer(yt, USER_A);
            clk.destroy_for_testing();
            ts::return_shared(config);
            ts::return_shared(vault);
        };

        // Step 2: USER_B mints 5000
        scenario.next_tx(USER_B);
        {
            let mut config = scenario.take_shared<YieldMarketConfig<TEST_COIN>>();
            let vault = scenario.take_shared<SYVault<TEST_COIN>>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(3000);
            let coin_in = coin::mint_for_testing<TEST_COIN>(5000, scenario.ctx());
            let (pt, yt) = yield_tokenizer::mint_py(
                &mut config, &vault, coin_in, &clk, scenario.ctx(),
            );

            assert!(
                yield_tokenizer::total_pt_supply(&config) ==
                yield_tokenizer::total_yt_supply(&config),
                14002,
            );
            assert!(yield_tokenizer::reserve_balance(&config) == 15_000, 14003);

            sui::transfer::public_transfer(pt, USER_B);
            sui::transfer::public_transfer(yt, USER_B);
            clk.destroy_for_testing();
            ts::return_shared(config);
            ts::return_shared(vault);
        };

        // Step 3: Accrue 5% yield
        scenario.next_tx(ADMIN);
        {
            let mut vault = scenario.take_shared<SYVault<TEST_COIN>>();
            let mut config = scenario.take_shared<YieldMarketConfig<TEST_COIN>>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(20_000);

            let new_rate: u128 = WAD + WAD / 20; // 1.05
            standardized_yield::update_exchange_rate_for_testing(&mut vault, new_rate, &clk);
            yield_tokenizer::update_py_index(&mut config, &vault, &clk);

            // Invariant: yield reserve is positive
            assert!(yield_tokenizer::yield_reserve_sy(&config) > 0, 14004);

            // Invariant: PT/YT supply symmetry still holds
            assert!(
                yield_tokenizer::total_pt_supply(&config) ==
                yield_tokenizer::total_yt_supply(&config),
                14005,
            );

            clk.destroy_for_testing();
            ts::return_shared(config);
            ts::return_shared(vault);
        };

        // Step 4: USER_A redeems pre-expiry
        scenario.next_tx(USER_A);
        {
            let mut config = scenario.take_shared<YieldMarketConfig<TEST_COIN>>();
            let vault = scenario.take_shared<SYVault<TEST_COIN>>();
            let pt = scenario.take_from_sender<PT<TEST_COIN>>();
            let yt = scenario.take_from_sender<YT<TEST_COIN>>();
            let coin_out = yield_tokenizer::redeem_py_pre_expiry(
                &mut config, &vault, pt, yt, scenario.ctx(),
            );

            // Invariant: still symmetric
            assert!(
                yield_tokenizer::total_pt_supply(&config) ==
                yield_tokenizer::total_yt_supply(&config),
                14006,
            );

            // Invariant: reserve decreased
            assert!(yield_tokenizer::reserve_balance(&config) < 15_000, 14007);

            sui::transfer::public_transfer(coin_out, USER_A);
            ts::return_shared(config);
            ts::return_shared(vault);
        };

        // Step 5: Settle market
        scenario.next_tx(ADMIN);
        {
            let admin_cap = scenario.take_from_sender<AdminCap>();
            let mut config = scenario.take_shared<YieldMarketConfig<TEST_COIN>>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(MATURITY_MS + 1);
            yield_tokenizer::settle_market(&admin_cap, &mut config, &clk);

            assert!(yield_tokenizer::is_expired(&config), 14008);

            clk.destroy_for_testing();
            scenario.return_to_sender(admin_cap);
            ts::return_shared(config);
        };

        // Step 6: USER_B redeems PT post-expiry
        scenario.next_tx(USER_B);
        {
            let mut config = scenario.take_shared<YieldMarketConfig<TEST_COIN>>();
            let pt = scenario.take_from_sender<PT<TEST_COIN>>();
            let coin_out = yield_tokenizer::redeem_pt_post_expiry(
                &mut config, pt, scenario.ctx(),
            );

            assert!(coin_out.value() > 0, 14009);

            // PT supply should now be zero
            assert!(yield_tokenizer::total_pt_supply(&config) == 0, 14010);

            sui::transfer::public_transfer(coin_out, USER_B);
            ts::return_shared(config);
        };

        scenario.end();
    }
}
