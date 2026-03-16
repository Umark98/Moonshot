#[test_only]
module crux::yield_tokenizer_tests {
    use sui::test_scenario::{Self as ts};
    use sui::clock;
    use sui::coin;

    use crux::standardized_yield::{Self, AdminCap, SYVault};
    use crux::yield_tokenizer::{Self, YieldMarketConfig, PT, YT};

    public struct TEST_COIN has drop {}

    const ADMIN: address = @0xAD;
    const USER: address = @0xB0B;
    const WAD: u128 = 1_000_000_000_000_000_000;
    const MATURITY_MS: u64 = 100_000_000; // 100 seconds

    fun setup(): ts::Scenario {
        let mut scenario = ts::begin(ADMIN);

        // Init SY module
        {
            standardized_yield::init_for_testing(scenario.ctx());
        };

        // Create SY vault
        scenario.next_tx(ADMIN);
        {
            let admin_cap = scenario.take_from_sender<AdminCap>();
            let mut clock = clock::create_for_testing(scenario.ctx());
            clock.set_for_testing(1000);
            standardized_yield::create_vault<TEST_COIN>(&admin_cap, &clock, scenario.ctx());
            scenario.return_to_sender(admin_cap);
            clock.destroy_for_testing();
        };

        // Create yield market
        scenario.next_tx(ADMIN);
        {
            let vault = scenario.take_shared<SYVault<TEST_COIN>>();
            let mut clock = clock::create_for_testing(scenario.ctx());
            clock.set_for_testing(1000);
            let admin_cap = scenario.take_from_sender<AdminCap>();
            yield_tokenizer::create_market<TEST_COIN>(
                &admin_cap,
                &vault,
                MATURITY_MS,
                &clock,
                scenario.ctx(),
            );
            scenario.return_to_sender(admin_cap);
            clock.destroy_for_testing();
            ts::return_shared(vault);
        };

        scenario
    }

    #[test]
    fun test_create_market() {
        let mut scenario = setup();

        scenario.next_tx(ADMIN);
        {
            let config = scenario.take_shared<YieldMarketConfig<TEST_COIN>>();
            assert!(yield_tokenizer::maturity_ms(&config) == MATURITY_MS);
            assert!(yield_tokenizer::initial_py_index(&config) == WAD);
            assert!(yield_tokenizer::current_py_index(&config) == WAD);
            assert!(!yield_tokenizer::is_expired(&config));
            assert!(yield_tokenizer::total_pt_supply(&config) == 0);
            assert!(yield_tokenizer::total_yt_supply(&config) == 0);
            ts::return_shared(config);
        };
        scenario.end();
    }

    #[test]
    fun test_mint_py() {
        let mut scenario = setup();

        // Mint PT + YT from Coin<T> directly
        scenario.next_tx(USER);
        {
            let mut config = scenario.take_shared<YieldMarketConfig<TEST_COIN>>();
            let vault = scenario.take_shared<SYVault<TEST_COIN>>();
            let deposit_coin = coin::mint_for_testing<TEST_COIN>(1000, scenario.ctx());
            let mut clock = clock::create_for_testing(scenario.ctx());
            clock.set_for_testing(2000);

            let (pt, yt) = yield_tokenizer::mint_py(&mut config, &vault, deposit_coin, &clock, scenario.ctx());

            assert!(yield_tokenizer::pt_amount(&pt) == 1000);
            assert!(yield_tokenizer::yt_amount(&yt) == 1000);
            assert!(yield_tokenizer::pt_maturity(&pt) == MATURITY_MS);
            assert!(yield_tokenizer::yt_maturity(&yt) == MATURITY_MS);
            assert!(yield_tokenizer::total_pt_supply(&config) == 1000);
            assert!(yield_tokenizer::total_yt_supply(&config) == 1000);

            sui::transfer::public_transfer(pt, USER);
            sui::transfer::public_transfer(yt, USER);
            clock.destroy_for_testing();
            ts::return_shared(config);
            ts::return_shared(vault);
        };
        scenario.end();
    }

    #[test]
    fun test_redeem_pre_expiry() {
        let mut scenario = setup();

        // Mint PT + YT from Coin<T>
        scenario.next_tx(USER);
        {
            let mut config = scenario.take_shared<YieldMarketConfig<TEST_COIN>>();
            let vault = scenario.take_shared<SYVault<TEST_COIN>>();
            let deposit_coin = coin::mint_for_testing<TEST_COIN>(1000, scenario.ctx());
            let mut clock = clock::create_for_testing(scenario.ctx());
            clock.set_for_testing(2000);
            let (pt, yt) = yield_tokenizer::mint_py(&mut config, &vault, deposit_coin, &clock, scenario.ctx());
            sui::transfer::public_transfer(pt, USER);
            sui::transfer::public_transfer(yt, USER);
            clock.destroy_for_testing();
            ts::return_shared(config);
            ts::return_shared(vault);
        };

        // Redeem PT + YT before expiry
        scenario.next_tx(USER);
        {
            let mut config = scenario.take_shared<YieldMarketConfig<TEST_COIN>>();
            let vault = scenario.take_shared<SYVault<TEST_COIN>>();
            let pt = scenario.take_from_sender<PT<TEST_COIN>>();
            let yt = scenario.take_from_sender<YT<TEST_COIN>>();

            let coin_returned = yield_tokenizer::redeem_py_pre_expiry(
                &mut config, &vault, pt, yt, scenario.ctx(),
            );

            assert!(coin_returned.value() == 1000);
            assert!(yield_tokenizer::total_pt_supply(&config) == 0);
            assert!(yield_tokenizer::total_yt_supply(&config) == 0);

            sui::transfer::public_transfer(coin_returned, USER);
            ts::return_shared(config);
            ts::return_shared(vault);
        };
        scenario.end();
    }

    #[test]
    fun test_split_merge_pt() {
        let mut scenario = setup();

        // Mint PT + YT from Coin<T>
        scenario.next_tx(USER);
        {
            let mut config = scenario.take_shared<YieldMarketConfig<TEST_COIN>>();
            let vault = scenario.take_shared<SYVault<TEST_COIN>>();
            let deposit_coin = coin::mint_for_testing<TEST_COIN>(1000, scenario.ctx());
            let mut clock = clock::create_for_testing(scenario.ctx());
            clock.set_for_testing(2000);
            let (pt, yt) = yield_tokenizer::mint_py(&mut config, &vault, deposit_coin, &clock, scenario.ctx());
            sui::transfer::public_transfer(pt, USER);
            sui::transfer::public_transfer(yt, USER);
            clock.destroy_for_testing();
            ts::return_shared(config);
            ts::return_shared(vault);
        };

        // Split and merge PT
        scenario.next_tx(USER);
        {
            let mut pt = scenario.take_from_sender<PT<TEST_COIN>>();
            let split_pt = yield_tokenizer::split_pt(&mut pt, 300, scenario.ctx());

            assert!(yield_tokenizer::pt_amount(&pt) == 700);
            assert!(yield_tokenizer::pt_amount(&split_pt) == 300);

            yield_tokenizer::merge_pt(&mut pt, split_pt);
            assert!(yield_tokenizer::pt_amount(&pt) == 1000);

            sui::transfer::public_transfer(pt, USER);
        };
        scenario.end();
    }

    #[test]
    fun test_split_merge_yt() {
        let mut scenario = setup();

        // Mint PT + YT from Coin<T>
        scenario.next_tx(USER);
        {
            let mut config = scenario.take_shared<YieldMarketConfig<TEST_COIN>>();
            let vault = scenario.take_shared<SYVault<TEST_COIN>>();
            let deposit_coin = coin::mint_for_testing<TEST_COIN>(1000, scenario.ctx());
            let mut clock = clock::create_for_testing(scenario.ctx());
            clock.set_for_testing(2000);
            let (pt, yt) = yield_tokenizer::mint_py(&mut config, &vault, deposit_coin, &clock, scenario.ctx());
            sui::transfer::public_transfer(pt, USER);
            sui::transfer::public_transfer(yt, USER);
            clock.destroy_for_testing();
            ts::return_shared(config);
            ts::return_shared(vault);
        };

        // Split and merge YT
        scenario.next_tx(USER);
        {
            let mut yt = scenario.take_from_sender<YT<TEST_COIN>>();
            let split_yt = yield_tokenizer::split_yt(&mut yt, 400, scenario.ctx());

            assert!(yield_tokenizer::yt_amount(&yt) == 600);
            assert!(yield_tokenizer::yt_amount(&split_yt) == 400);

            yield_tokenizer::merge_yt(&mut yt, split_yt);
            assert!(yield_tokenizer::yt_amount(&yt) == 1000);

            sui::transfer::public_transfer(yt, USER);
        };
        scenario.end();
    }

    #[test]
    fun test_settle_market() {
        let mut scenario = setup();

        scenario.next_tx(ADMIN);
        {
            let mut config = scenario.take_shared<YieldMarketConfig<TEST_COIN>>();
            let mut clock = clock::create_for_testing(scenario.ctx());
            clock.set_for_testing(MATURITY_MS + 1); // past maturity

            let admin_cap = scenario.take_from_sender<AdminCap>();
            yield_tokenizer::settle_market(&admin_cap, &mut config, &clock);
            scenario.return_to_sender(admin_cap);
            assert!(yield_tokenizer::is_expired(&config));
            assert!(yield_tokenizer::settlement_py_index(&config) == WAD);

            clock.destroy_for_testing();
            ts::return_shared(config);
        };
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = 301)] // EMarketNotExpired
    fun test_settle_before_maturity() {
        let mut scenario = setup();

        scenario.next_tx(ADMIN);
        {
            let mut config = scenario.take_shared<YieldMarketConfig<TEST_COIN>>();
            let mut clock = clock::create_for_testing(scenario.ctx());
            clock.set_for_testing(2000); // before maturity

            let admin_cap = scenario.take_from_sender<AdminCap>();
            yield_tokenizer::settle_market(&admin_cap, &mut config, &clock);
            scenario.return_to_sender(admin_cap);

            clock.destroy_for_testing();
            ts::return_shared(config);
        };
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = 300)] // EMarketExpired
    fun test_mint_after_expiry() {
        let mut scenario = setup();

        // Settle the market
        scenario.next_tx(ADMIN);
        {
            let mut config = scenario.take_shared<YieldMarketConfig<TEST_COIN>>();
            let mut clock = clock::create_for_testing(scenario.ctx());
            clock.set_for_testing(MATURITY_MS + 1);
            let admin_cap = scenario.take_from_sender<AdminCap>();
            yield_tokenizer::settle_market(&admin_cap, &mut config, &clock);
            scenario.return_to_sender(admin_cap);
            clock.destroy_for_testing();
            ts::return_shared(config);
        };

        // Try to mint — should fail
        scenario.next_tx(USER);
        {
            let vault = scenario.take_shared<SYVault<TEST_COIN>>();
            let deposit_coin = coin::mint_for_testing<TEST_COIN>(1000, scenario.ctx());

            let mut config = scenario.take_shared<YieldMarketConfig<TEST_COIN>>();
            let mut clock = clock::create_for_testing(scenario.ctx());
            clock.set_for_testing(MATURITY_MS + 2);

            let (pt, yt) = yield_tokenizer::mint_py(&mut config, &vault, deposit_coin, &clock, scenario.ctx());

            sui::transfer::public_transfer(pt, USER);
            sui::transfer::public_transfer(yt, USER);
            clock.destroy_for_testing();
            ts::return_shared(config);
            ts::return_shared(vault);
        };
        scenario.end();
    }

    #[test]
    fun test_pending_yield_zero_initially() {
        let mut scenario = setup();

        // Mint PT + YT from Coin<T>
        scenario.next_tx(USER);
        {
            let mut config = scenario.take_shared<YieldMarketConfig<TEST_COIN>>();
            let vault = scenario.take_shared<SYVault<TEST_COIN>>();
            let deposit_coin = coin::mint_for_testing<TEST_COIN>(1000, scenario.ctx());
            let mut clock = clock::create_for_testing(scenario.ctx());
            clock.set_for_testing(2000);
            let (pt, yt) = yield_tokenizer::mint_py(&mut config, &vault, deposit_coin, &clock, scenario.ctx());

            // No yield accrued yet
            let pending = yield_tokenizer::pending_yield(&config, &yt);
            assert!(pending == 0);

            sui::transfer::public_transfer(pt, USER);
            sui::transfer::public_transfer(yt, USER);
            clock.destroy_for_testing();
            ts::return_shared(config);
            ts::return_shared(vault);
        };
        scenario.end();
    }

    #[test]
    fun test_update_py_index_accrues_yield() {
        let mut scenario = setup();

        // Mint PT + YT from Coin<T>
        scenario.next_tx(USER);
        {
            let mut config = scenario.take_shared<YieldMarketConfig<TEST_COIN>>();
            let vault = scenario.take_shared<SYVault<TEST_COIN>>();
            let deposit_coin = coin::mint_for_testing<TEST_COIN>(1000, scenario.ctx());
            let mut clock = clock::create_for_testing(scenario.ctx());
            clock.set_for_testing(2000);
            let (pt, yt) = yield_tokenizer::mint_py(&mut config, &vault, deposit_coin, &clock, scenario.ctx());
            sui::transfer::public_transfer(pt, USER);
            sui::transfer::public_transfer(yt, USER);
            clock.destroy_for_testing();
            ts::return_shared(config);
            ts::return_shared(vault);
        };

        // Update exchange rate → triggers PY index update
        scenario.next_tx(ADMIN);
        {
            let mut vault = scenario.take_shared<SYVault<TEST_COIN>>();
            let mut config = scenario.take_shared<YieldMarketConfig<TEST_COIN>>();
            let mut clock = clock::create_for_testing(scenario.ctx());
            clock.set_for_testing(50000);

            // Increase exchange rate by 10%
            let new_rate = WAD + WAD / 10; // 1.1 WAD
            standardized_yield::update_exchange_rate_for_testing(&mut vault, new_rate, &clock);
            yield_tokenizer::update_py_index(&mut config, &vault, &clock);

            assert!(yield_tokenizer::current_py_index(&config) == new_rate);
            assert!(yield_tokenizer::yield_reserve_sy(&config) > 0);

            clock.destroy_for_testing();
            ts::return_shared(config);
            ts::return_shared(vault);
        };
        scenario.end();
    }
}
