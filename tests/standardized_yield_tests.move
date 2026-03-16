#[test_only]
module crux::standardized_yield_tests {
    use sui::test_scenario::{Self as ts};
    use sui::clock;
    use sui::coin;

    use crux::standardized_yield::{Self, AdminCap, SYVault};

    // ===== Test Coin =====
    public struct TEST_COIN has drop {}

    const ADMIN: address = @0xAD;
    const USER: address = @0xB0B;

    // ===== Helpers =====

    fun setup(): ts::Scenario {
        let mut scenario = ts::begin(ADMIN);
        {
            standardized_yield::init_for_testing(scenario.ctx());
        };
        scenario
    }

    fun create_test_vault(scenario: &mut ts::Scenario) {
        scenario.next_tx(ADMIN);
        {
            let admin_cap = scenario.take_from_sender<AdminCap>();
            let clock = clock::create_for_testing(scenario.ctx());
            standardized_yield::create_vault<TEST_COIN>(&admin_cap, &clock, scenario.ctx());
            scenario.return_to_sender(admin_cap);
            clock.destroy_for_testing();
        };
    }

    // ===== Tests =====

    #[test]
    fun test_create_vault() {
        let mut scenario = setup();
        create_test_vault(&mut scenario);

        scenario.next_tx(ADMIN);
        {
            let vault = scenario.take_shared<SYVault<TEST_COIN>>();
            assert!(standardized_yield::exchange_rate(&vault) == 1_000_000_000_000_000_000); // WAD
            assert!(standardized_yield::total_supply(&vault) == 0);
            assert!(standardized_yield::total_underlying(&vault) == 0);
            assert!(!standardized_yield::is_paused(&vault));
            ts::return_shared(vault);
        };
        scenario.end();
    }

    #[test]
    fun test_deposit() {
        let mut scenario = setup();
        create_test_vault(&mut scenario);

        scenario.next_tx(USER);
        {
            let mut vault = scenario.take_shared<SYVault<TEST_COIN>>();
            let deposit_coin = coin::mint_for_testing<TEST_COIN>(1000, scenario.ctx());
            let sy_token = standardized_yield::deposit(&mut vault, deposit_coin, scenario.ctx());

            // At 1:1 rate, 1000 underlying = 1000 SY
            assert!(standardized_yield::sy_amount(&sy_token) == 1000);
            assert!(standardized_yield::total_supply(&vault) == 1000);
            assert!(standardized_yield::total_underlying(&vault) == 1000);

            sui::transfer::public_transfer(sy_token, USER);
            ts::return_shared(vault);
        };
        scenario.end();
    }

    #[test]
    fun test_deposit_and_redeem() {
        let mut scenario = setup();
        create_test_vault(&mut scenario);

        // Deposit
        scenario.next_tx(USER);
        {
            let mut vault = scenario.take_shared<SYVault<TEST_COIN>>();
            let deposit_coin = coin::mint_for_testing<TEST_COIN>(1000, scenario.ctx());
            let sy_token = standardized_yield::deposit(&mut vault, deposit_coin, scenario.ctx());
            sui::transfer::public_transfer(sy_token, USER);
            ts::return_shared(vault);
        };

        // Redeem
        scenario.next_tx(USER);
        {
            let mut vault = scenario.take_shared<SYVault<TEST_COIN>>();
            let sy_token = scenario.take_from_sender<standardized_yield::SYToken<TEST_COIN>>();
            let coin_out = standardized_yield::redeem(&mut vault, sy_token, scenario.ctx());

            assert!(coin_out.value() == 1000);
            assert!(standardized_yield::total_supply(&vault) == 0);
            assert!(standardized_yield::total_underlying(&vault) == 0);

            sui::transfer::public_transfer(coin_out, USER);
            ts::return_shared(vault);
        };
        scenario.end();
    }

    #[test]
    fun test_exchange_rate_update() {
        let mut scenario = setup();
        create_test_vault(&mut scenario);

        scenario.next_tx(ADMIN);
        {
            let mut vault = scenario.take_shared<SYVault<TEST_COIN>>();
            let clock = clock::create_for_testing(scenario.ctx());

            // Update rate to 1.05 (5% yield accrued)
            let new_rate = 1_050_000_000_000_000_000; // 1.05 WAD
            standardized_yield::update_exchange_rate(&mut vault, new_rate, &clock);

            assert!(standardized_yield::exchange_rate(&vault) == new_rate);
            clock.destroy_for_testing();
            ts::return_shared(vault);
        };
        scenario.end();
    }

    #[test]
    fun test_deposit_with_higher_rate() {
        let mut scenario = setup();
        create_test_vault(&mut scenario);

        // Update exchange rate to 2.0 before depositing
        scenario.next_tx(ADMIN);
        {
            let mut vault = scenario.take_shared<SYVault<TEST_COIN>>();
            let clock = clock::create_for_testing(scenario.ctx());
            let new_rate = 2_000_000_000_000_000_000; // 2.0 WAD
            standardized_yield::update_exchange_rate(&mut vault, new_rate, &clock);
            clock.destroy_for_testing();
            ts::return_shared(vault);
        };

        // Deposit 1000 underlying at 2.0 rate → should get 500 SY
        scenario.next_tx(USER);
        {
            let mut vault = scenario.take_shared<SYVault<TEST_COIN>>();
            let deposit_coin = coin::mint_for_testing<TEST_COIN>(1000, scenario.ctx());
            let sy_token = standardized_yield::deposit(&mut vault, deposit_coin, scenario.ctx());

            assert!(standardized_yield::sy_amount(&sy_token) == 500);
            sui::transfer::public_transfer(sy_token, USER);
            ts::return_shared(vault);
        };
        scenario.end();
    }

    #[test]
    fun test_split_and_merge() {
        let mut scenario = setup();
        create_test_vault(&mut scenario);

        // Deposit
        scenario.next_tx(USER);
        {
            let mut vault = scenario.take_shared<SYVault<TEST_COIN>>();
            let deposit_coin = coin::mint_for_testing<TEST_COIN>(1000, scenario.ctx());
            let sy_token = standardized_yield::deposit(&mut vault, deposit_coin, scenario.ctx());
            sui::transfer::public_transfer(sy_token, USER);
            ts::return_shared(vault);
        };

        // Split
        scenario.next_tx(USER);
        {
            let mut sy_token = scenario.take_from_sender<standardized_yield::SYToken<TEST_COIN>>();
            let split_token = standardized_yield::split(&mut sy_token, 300, scenario.ctx());

            assert!(standardized_yield::sy_amount(&sy_token) == 700);
            assert!(standardized_yield::sy_amount(&split_token) == 300);

            // Merge back
            standardized_yield::merge(&mut sy_token, split_token);
            assert!(standardized_yield::sy_amount(&sy_token) == 1000);

            sui::transfer::public_transfer(sy_token, USER);
        };
        scenario.end();
    }

    #[test]
    fun test_pause_unpause() {
        let mut scenario = setup();
        create_test_vault(&mut scenario);

        scenario.next_tx(ADMIN);
        {
            let admin_cap = scenario.take_from_sender<AdminCap>();
            let mut vault = scenario.take_shared<SYVault<TEST_COIN>>();

            standardized_yield::pause_vault(&admin_cap, &mut vault);
            assert!(standardized_yield::is_paused(&vault));

            standardized_yield::unpause_vault(&admin_cap, &mut vault);
            assert!(!standardized_yield::is_paused(&vault));

            scenario.return_to_sender(admin_cap);
            ts::return_shared(vault);
        };
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = 203)] // EVaultPaused
    fun test_deposit_paused_vault() {
        let mut scenario = setup();
        create_test_vault(&mut scenario);

        // Pause vault
        scenario.next_tx(ADMIN);
        {
            let admin_cap = scenario.take_from_sender<AdminCap>();
            let mut vault = scenario.take_shared<SYVault<TEST_COIN>>();
            standardized_yield::pause_vault(&admin_cap, &mut vault);
            scenario.return_to_sender(admin_cap);
            ts::return_shared(vault);
        };

        // Try to deposit — should fail
        scenario.next_tx(USER);
        {
            let mut vault = scenario.take_shared<SYVault<TEST_COIN>>();
            let deposit_coin = coin::mint_for_testing<TEST_COIN>(1000, scenario.ctx());
            let sy_token = standardized_yield::deposit(&mut vault, deposit_coin, scenario.ctx());
            sui::transfer::public_transfer(sy_token, USER);
            ts::return_shared(vault);
        };
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = 200)] // EZeroDeposit
    fun test_zero_deposit() {
        let mut scenario = setup();
        create_test_vault(&mut scenario);

        scenario.next_tx(USER);
        {
            let mut vault = scenario.take_shared<SYVault<TEST_COIN>>();
            let deposit_coin = coin::mint_for_testing<TEST_COIN>(0, scenario.ctx());
            let sy_token = standardized_yield::deposit(&mut vault, deposit_coin, scenario.ctx());
            sui::transfer::public_transfer(sy_token, USER);
            ts::return_shared(vault);
        };
        scenario.end();
    }

    #[test]
    fun test_preview_deposit() {
        let mut scenario = setup();
        create_test_vault(&mut scenario);

        scenario.next_tx(ADMIN);
        {
            let vault = scenario.take_shared<SYVault<TEST_COIN>>();
            let preview = standardized_yield::preview_deposit(&vault, 1000);
            assert!(preview == 1000); // 1:1 at WAD rate
            ts::return_shared(vault);
        };
        scenario.end();
    }

    #[test]
    fun test_preview_redeem() {
        let mut scenario = setup();
        create_test_vault(&mut scenario);

        scenario.next_tx(ADMIN);
        {
            let vault = scenario.take_shared<SYVault<TEST_COIN>>();
            let preview = standardized_yield::preview_redeem(&vault, 1000);
            assert!(preview == 1000); // 1:1 at WAD rate
            ts::return_shared(vault);
        };
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = 204)] // EInvalidExchangeRate
    fun test_exchange_rate_decrease_fails() {
        let mut scenario = setup();
        create_test_vault(&mut scenario);

        scenario.next_tx(ADMIN);
        {
            let mut vault = scenario.take_shared<SYVault<TEST_COIN>>();
            let clock = clock::create_for_testing(scenario.ctx());

            // First increase
            standardized_yield::update_exchange_rate(
                &mut vault,
                1_100_000_000_000_000_000,
                &clock,
            );

            // Try to decrease — should fail
            standardized_yield::update_exchange_rate(
                &mut vault,
                1_000_000_000_000_000_000,
                &clock,
            );

            clock.destroy_for_testing();
            ts::return_shared(vault);
        };
        scenario.end();
    }
}
