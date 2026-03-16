#[test_only]
module crux::crux_token_tests {
    use sui::test_scenario::{Self as ts};
    use sui::coin::TreasuryCap;

    use crux::crux_token::{Self, CRUX_TOKEN, CRUXAdminCap, TokenDistribution};

    const ADMIN: address = @0xAD;
    const RECIPIENT: address = @0xB0B;

    fun setup(): ts::Scenario {
        let mut scenario = ts::begin(ADMIN);
        {
            crux_token::init_for_testing(scenario.ctx());
        };
        scenario
    }

    #[test]
    fun test_init_creates_distribution() {
        let mut scenario = setup();

        ts::next_tx(&mut scenario, ADMIN);
        {
            let dist = scenario.take_shared<TokenDistribution>();
            assert!(crux_token::total_supply(&dist) == 1_000_000_000);
            assert!(crux_token::minted_so_far(&dist) == 0);
            ts::return_shared(dist);
        };

        // Admin should have TreasuryCap and CRUXAdminCap
        ts::next_tx(&mut scenario, ADMIN);
        {
            let treasury = scenario.take_from_sender<TreasuryCap<CRUX_TOKEN>>();
            let admin_cap = scenario.take_from_sender<CRUXAdminCap>();
            scenario.return_to_sender(treasury);
            scenario.return_to_sender(admin_cap);
        };
        scenario.end();
    }

    #[test]
    fun test_mint_tokens() {
        let mut scenario = setup();

        ts::next_tx(&mut scenario, ADMIN);
        {
            let admin_cap = scenario.take_from_sender<CRUXAdminCap>();
            let mut treasury = scenario.take_from_sender<TreasuryCap<CRUX_TOKEN>>();
            let mut dist = scenario.take_shared<TokenDistribution>();

            crux_token::mint(
                &admin_cap,
                &mut treasury,
                &mut dist,
                1_000_000,
                RECIPIENT,
                b"community",
                scenario.ctx(),
            );

            assert!(crux_token::minted_so_far(&dist) == 1_000_000);

            scenario.return_to_sender(admin_cap);
            scenario.return_to_sender(treasury);
            ts::return_shared(dist);
        };
        scenario.end();
    }

    #[test]
    fun test_multiple_mints() {
        let mut scenario = setup();

        ts::next_tx(&mut scenario, ADMIN);
        {
            let admin_cap = scenario.take_from_sender<CRUXAdminCap>();
            let mut treasury = scenario.take_from_sender<TreasuryCap<CRUX_TOKEN>>();
            let mut dist = scenario.take_shared<TokenDistribution>();

            crux_token::mint(&admin_cap, &mut treasury, &mut dist, 100_000_000, RECIPIENT, b"community", scenario.ctx());
            crux_token::mint(&admin_cap, &mut treasury, &mut dist, 200_000_000, RECIPIENT, b"team", scenario.ctx());
            crux_token::mint(&admin_cap, &mut treasury, &mut dist, 150_000_000, @0xCAFE, b"investor", scenario.ctx());

            assert!(crux_token::minted_so_far(&dist) == 450_000_000);

            scenario.return_to_sender(admin_cap);
            scenario.return_to_sender(treasury);
            ts::return_shared(dist);
        };
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = 980)] // EExceedsAllocation
    fun test_mint_exceeds_total_supply() {
        let mut scenario = setup();

        ts::next_tx(&mut scenario, ADMIN);
        {
            let admin_cap = scenario.take_from_sender<CRUXAdminCap>();
            let mut treasury = scenario.take_from_sender<TreasuryCap<CRUX_TOKEN>>();
            let mut dist = scenario.take_shared<TokenDistribution>();

            // Try to mint more than 1B
            crux_token::mint(
                &admin_cap,
                &mut treasury,
                &mut dist,
                1_000_000_001,
                RECIPIENT,
                b"community",
                scenario.ctx(),
            );

            scenario.return_to_sender(admin_cap);
            scenario.return_to_sender(treasury);
            ts::return_shared(dist);
        };
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = 981)] // EZeroAmount
    fun test_mint_zero() {
        let mut scenario = setup();

        ts::next_tx(&mut scenario, ADMIN);
        {
            let admin_cap = scenario.take_from_sender<CRUXAdminCap>();
            let mut treasury = scenario.take_from_sender<TreasuryCap<CRUX_TOKEN>>();
            let mut dist = scenario.take_shared<TokenDistribution>();

            crux_token::mint(
                &admin_cap,
                &mut treasury,
                &mut dist,
                0,
                RECIPIENT,
                b"community",
                scenario.ctx(),
            );

            scenario.return_to_sender(admin_cap);
            scenario.return_to_sender(treasury);
            ts::return_shared(dist);
        };
        scenario.end();
    }

    #[test]
    fun test_mint_exact_total_supply() {
        let mut scenario = setup();

        ts::next_tx(&mut scenario, ADMIN);
        {
            let admin_cap = scenario.take_from_sender<CRUXAdminCap>();
            let mut treasury = scenario.take_from_sender<TreasuryCap<CRUX_TOKEN>>();
            let mut dist = scenario.take_shared<TokenDistribution>();

            // Mint exactly the total supply
            crux_token::mint(
                &admin_cap,
                &mut treasury,
                &mut dist,
                1_000_000_000,
                RECIPIENT,
                b"all",
                scenario.ctx(),
            );

            assert!(crux_token::minted_so_far(&dist) == 1_000_000_000);

            scenario.return_to_sender(admin_cap);
            scenario.return_to_sender(treasury);
            ts::return_shared(dist);
        };
        scenario.end();
    }
}
