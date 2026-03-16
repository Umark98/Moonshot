#[test_only]
module crux::fee_collector_tests {
    use sui::test_scenario::{Self as ts};
    use sui::coin;

    use crux::fee_collector::{Self, FeeAdminCap, FeeVault};

    public struct FEE_COIN has drop {}

    const ADMIN: address = @0xAD;
    const TREASURY: address = @0xFEE;

    fun setup(): ts::Scenario {
        let mut scenario = ts::begin(ADMIN);
        {
            fee_collector::init_for_testing(scenario.ctx());
        };
        scenario
    }

    #[test]
    fun test_create_fee_vault() {
        let mut scenario = setup();

        scenario.next_tx(ADMIN);
        {
            let admin_cap = scenario.take_from_sender<FeeAdminCap>();
            fee_collector::create_vault<FEE_COIN>(&admin_cap, TREASURY, scenario.ctx());
            scenario.return_to_sender(admin_cap);
        };

        scenario.next_tx(ADMIN);
        {
            let vault = scenario.take_shared<FeeVault<FEE_COIN>>();
            assert!(fee_collector::pending_fees(&vault) == 0);
            assert!(fee_collector::total_collected(&vault) == 0);
            ts::return_shared(vault);
        };
        scenario.end();
    }

    #[test]
    fun test_collect_fees() {
        let mut scenario = setup();

        scenario.next_tx(ADMIN);
        {
            let admin_cap = scenario.take_from_sender<FeeAdminCap>();
            fee_collector::create_vault<FEE_COIN>(&admin_cap, TREASURY, scenario.ctx());
            scenario.return_to_sender(admin_cap);
        };

        scenario.next_tx(ADMIN);
        {
            let mut vault = scenario.take_shared<FeeVault<FEE_COIN>>();
            let fee_coin = coin::mint_for_testing<FEE_COIN>(1000, scenario.ctx());
            fee_collector::collect_fees(&mut vault, fee_coin, b"FEE_COIN");

            assert!(fee_collector::pending_fees(&vault) == 1000);
            assert!(fee_collector::total_collected(&vault) == 1000);

            ts::return_shared(vault);
        };
        scenario.end();
    }

    #[test]
    fun test_distribute_fees() {
        let mut scenario = setup();

        scenario.next_tx(ADMIN);
        {
            let admin_cap = scenario.take_from_sender<FeeAdminCap>();
            fee_collector::create_vault<FEE_COIN>(&admin_cap, TREASURY, scenario.ctx());
            scenario.return_to_sender(admin_cap);
        };

        // Collect 1000 fees
        scenario.next_tx(ADMIN);
        {
            let mut vault = scenario.take_shared<FeeVault<FEE_COIN>>();
            let fee_coin = coin::mint_for_testing<FEE_COIN>(1000, scenario.ctx());
            fee_collector::collect_fees(&mut vault, fee_coin, b"FEE_COIN");
            ts::return_shared(vault);
        };

        // Distribute: 80% to stakers, 20% to treasury
        scenario.next_tx(ADMIN);
        {
            let admin_cap = scenario.take_from_sender<FeeAdminCap>();
            let mut vault = scenario.take_shared<FeeVault<FEE_COIN>>();

            let staker_coin = fee_collector::distribute_fees(&admin_cap, &mut vault, scenario.ctx());

            // Staker gets 800 (80%)
            assert!(staker_coin.value() == 800);
            // Treasury gets 200 (20%) — sent internally via public_transfer
            assert!(fee_collector::pending_fees(&vault) == 0);

            sui::transfer::public_transfer(staker_coin, ADMIN);
            scenario.return_to_sender(admin_cap);
            ts::return_shared(vault);
        };
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = 901)] // EInsufficientFees
    fun test_distribute_empty_vault() {
        let mut scenario = setup();

        scenario.next_tx(ADMIN);
        {
            let admin_cap = scenario.take_from_sender<FeeAdminCap>();
            fee_collector::create_vault<FEE_COIN>(&admin_cap, TREASURY, scenario.ctx());
            scenario.return_to_sender(admin_cap);
        };

        scenario.next_tx(ADMIN);
        {
            let admin_cap = scenario.take_from_sender<FeeAdminCap>();
            let mut vault = scenario.take_shared<FeeVault<FEE_COIN>>();

            let staker_coin = fee_collector::distribute_fees(&admin_cap, &mut vault, scenario.ctx());

            sui::transfer::public_transfer(staker_coin, ADMIN);
            scenario.return_to_sender(admin_cap);
            ts::return_shared(vault);
        };
        scenario.end();
    }

    #[test]
    fun test_multiple_fee_collections() {
        let mut scenario = setup();

        scenario.next_tx(ADMIN);
        {
            let admin_cap = scenario.take_from_sender<FeeAdminCap>();
            fee_collector::create_vault<FEE_COIN>(&admin_cap, TREASURY, scenario.ctx());
            scenario.return_to_sender(admin_cap);
        };

        // Collect fees multiple times
        scenario.next_tx(ADMIN);
        {
            let mut vault = scenario.take_shared<FeeVault<FEE_COIN>>();

            let fee1 = coin::mint_for_testing<FEE_COIN>(500, scenario.ctx());
            fee_collector::collect_fees(&mut vault, fee1, b"FEE_COIN");

            let fee2 = coin::mint_for_testing<FEE_COIN>(300, scenario.ctx());
            fee_collector::collect_fees(&mut vault, fee2, b"FEE_COIN");

            let fee3 = coin::mint_for_testing<FEE_COIN>(200, scenario.ctx());
            fee_collector::collect_fees(&mut vault, fee3, b"FEE_COIN");

            assert!(fee_collector::pending_fees(&vault) == 1000);
            assert!(fee_collector::total_collected(&vault) == 1000);

            ts::return_shared(vault);
        };
        scenario.end();
    }
}
