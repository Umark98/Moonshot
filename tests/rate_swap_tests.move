#[test_only]
module crux::rate_swap_tests {
    use sui::test_scenario::{Self as ts};
    use sui::clock;

    use crux::rate_swap::{Self, SwapOffer, SwapContract, AdminCap};

    const ALICE: address = @0xA1;
    const BOB: address = @0xB0B;

    const WAD: u128 = 1_000_000_000_000_000_000;
    const MATURITY: u64 = 100_000_000; // 100s in the future

    #[test]
    fun test_create_offer() {
        let mut scenario = ts::begin(ALICE);
        {
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(1000);

            let fixed_rate = WAD / 20; // 5%
            let notional = 10_000u64;
            let collateral = 1_000u64; // 10% of notional

            let offer_id = rate_swap::create_offer(
                true, // pay fixed
                notional,
                fixed_rate,
                MATURITY,
                collateral,
                &clk,
                scenario.ctx(),
            );
            let _ = offer_id;

            clk.destroy_for_testing();
        };

        ts::next_tx(&mut scenario, ALICE);
        {
            let offer = scenario.take_shared<SwapOffer>();
            let (creator, is_pay_fixed, notional, fixed_rate, maturity, collateral, is_taken) =
                rate_swap::offer_details(&offer);

            assert!(creator == ALICE);
            assert!(is_pay_fixed == true);
            assert!(notional == 10_000);
            assert!(fixed_rate == WAD / 20);
            assert!(maturity == MATURITY);
            assert!(collateral == 1_000);
            assert!(is_taken == false);

            ts::return_shared(offer);
        };
        scenario.end();
    }

    #[test]
    fun test_accept_offer() {
        let mut scenario = ts::begin(ALICE);
        {
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(1000);

            rate_swap::create_offer(
                true, 10_000, WAD / 20, MATURITY, 1_000, &clk, scenario.ctx(),
            );
            clk.destroy_for_testing();
        };

        // Bob accepts
        ts::next_tx(&mut scenario, BOB);
        {
            let mut offer = scenario.take_shared<SwapOffer>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(2000);

            let swap_id = rate_swap::accept_offer(&mut offer, 1_000, &clk, scenario.ctx());
            let _ = swap_id;

            // Offer should be marked as taken
            let (_, _, _, _, _, _, is_taken) = rate_swap::offer_details(&offer);
            assert!(is_taken == true);

            clk.destroy_for_testing();
            ts::return_shared(offer);
        };

        // Verify swap contract
        ts::next_tx(&mut scenario, BOB);
        {
            let swap = scenario.take_shared<SwapContract>();
            let (fixed_payer, variable_payer, notional, fixed_rate, _start, _maturity, _settle_rate, is_settled, coll_fixed, coll_var) =
                rate_swap::swap_details(&swap);

            // Alice is pay-fixed, Bob is pay-variable
            assert!(fixed_payer == ALICE);
            assert!(variable_payer == BOB);
            assert!(notional == 10_000);
            assert!(fixed_rate == WAD / 20);
            assert!(!is_settled);
            assert!(coll_fixed == 1_000);
            assert!(coll_var == 1_000);

            ts::return_shared(swap);
        };
        scenario.end();
    }

    #[test]
    fun test_settle_fixed_payer_wins() {
        let mut scenario = ts::begin(ALICE);
        {
            rate_swap::init_for_testing(scenario.ctx());
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(1000);
            rate_swap::create_offer(true, 10_000, WAD / 20, MATURITY, 1_000, &clk, scenario.ctx());
            clk.destroy_for_testing();
        };

        ts::next_tx(&mut scenario, BOB);
        {
            let mut offer = scenario.take_shared<SwapOffer>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(2000);
            rate_swap::accept_offer(&mut offer, 1_000, &clk, scenario.ctx());
            clk.destroy_for_testing();
            ts::return_shared(offer);
        };

        // Settle: variable rate = 8% > fixed rate = 5%, fixed payer wins
        ts::next_tx(&mut scenario, ALICE);
        {
            let admin_cap = scenario.take_from_sender<AdminCap>();
            let mut swap = scenario.take_shared<SwapContract>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(MATURITY + 1);

            let variable_rate = WAD * 8 / 100; // 8%
            rate_swap::settle_swap(&admin_cap, &mut swap, variable_rate, &clk);

            assert!(rate_swap::is_settled(&swap));

            let (_, _, _, _, _, _, settlement_rate, is_settled, _, _) =
                rate_swap::swap_details(&swap);
            assert!(is_settled);
            assert!(settlement_rate == variable_rate);

            clk.destroy_for_testing();
            scenario.return_to_sender(admin_cap);
            ts::return_shared(swap);
        };
        scenario.end();
    }

    #[test]
    fun test_settle_variable_payer_wins() {
        let mut scenario = ts::begin(ALICE);
        {
            rate_swap::init_for_testing(scenario.ctx());
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(1000);
            rate_swap::create_offer(true, 10_000, WAD / 20, MATURITY, 1_000, &clk, scenario.ctx());
            clk.destroy_for_testing();
        };

        ts::next_tx(&mut scenario, BOB);
        {
            let mut offer = scenario.take_shared<SwapOffer>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(2000);
            rate_swap::accept_offer(&mut offer, 1_000, &clk, scenario.ctx());
            clk.destroy_for_testing();
            ts::return_shared(offer);
        };

        // Settle: variable rate = 2% < fixed rate = 5%, variable payer wins
        ts::next_tx(&mut scenario, ALICE);
        {
            let admin_cap = scenario.take_from_sender<AdminCap>();
            let mut swap = scenario.take_shared<SwapContract>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(MATURITY + 1);

            let variable_rate = WAD * 2 / 100; // 2%
            rate_swap::settle_swap(&admin_cap, &mut swap, variable_rate, &clk);

            assert!(rate_swap::is_settled(&swap));

            clk.destroy_for_testing();
            scenario.return_to_sender(admin_cap);
            ts::return_shared(swap);
        };
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = 851)] // ESwapNotExpired
    fun test_settle_before_maturity() {
        let mut scenario = ts::begin(ALICE);
        {
            rate_swap::init_for_testing(scenario.ctx());
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(1000);
            rate_swap::create_offer(true, 10_000, WAD / 20, MATURITY, 1_000, &clk, scenario.ctx());
            clk.destroy_for_testing();
        };

        ts::next_tx(&mut scenario, BOB);
        {
            let mut offer = scenario.take_shared<SwapOffer>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(2000);
            rate_swap::accept_offer(&mut offer, 1_000, &clk, scenario.ctx());
            clk.destroy_for_testing();
            ts::return_shared(offer);
        };

        ts::next_tx(&mut scenario, ALICE);
        {
            let admin_cap = scenario.take_from_sender<AdminCap>();
            let mut swap = scenario.take_shared<SwapContract>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(50_000); // before maturity

            rate_swap::settle_swap(&admin_cap, &mut swap, WAD / 10, &clk);

            clk.destroy_for_testing();
            scenario.return_to_sender(admin_cap);
            ts::return_shared(swap);
        };
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = 852)] // EAlreadySettled
    fun test_double_settle() {
        let mut scenario = ts::begin(ALICE);
        {
            rate_swap::init_for_testing(scenario.ctx());
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(1000);
            rate_swap::create_offer(true, 10_000, WAD / 20, MATURITY, 1_000, &clk, scenario.ctx());
            clk.destroy_for_testing();
        };

        ts::next_tx(&mut scenario, BOB);
        {
            let mut offer = scenario.take_shared<SwapOffer>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(2000);
            rate_swap::accept_offer(&mut offer, 1_000, &clk, scenario.ctx());
            clk.destroy_for_testing();
            ts::return_shared(offer);
        };

        ts::next_tx(&mut scenario, ALICE);
        {
            let admin_cap = scenario.take_from_sender<AdminCap>();
            let mut swap = scenario.take_shared<SwapContract>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(MATURITY + 1);
            rate_swap::settle_swap(&admin_cap, &mut swap, WAD / 10, &clk);
            // Try again -- should fail
            rate_swap::settle_swap(&admin_cap, &mut swap, WAD / 10, &clk);

            clk.destroy_for_testing();
            scenario.return_to_sender(admin_cap);
            ts::return_shared(swap);
        };
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = 854)] // EOfferAlreadyTaken
    fun test_accept_taken_offer() {
        let mut scenario = ts::begin(ALICE);
        {
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(1000);
            rate_swap::create_offer(true, 10_000, WAD / 20, MATURITY, 1_000, &clk, scenario.ctx());
            clk.destroy_for_testing();
        };

        // Bob accepts
        ts::next_tx(&mut scenario, BOB);
        {
            let mut offer = scenario.take_shared<SwapOffer>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(2000);
            rate_swap::accept_offer(&mut offer, 1_000, &clk, scenario.ctx());
            clk.destroy_for_testing();
            ts::return_shared(offer);
        };

        // Someone else tries to accept — should fail
        ts::next_tx(&mut scenario, @0xCAFE);
        {
            let mut offer = scenario.take_shared<SwapOffer>();
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(3000);
            rate_swap::accept_offer(&mut offer, 1_000, &clk, scenario.ctx());
            clk.destroy_for_testing();
            ts::return_shared(offer);
        };
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = 853)] // EInsufficientCollateral
    fun test_insufficient_collateral() {
        let mut scenario = ts::begin(ALICE);
        {
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(1000);

            // 10% of 10000 = 1000 minimum, posting only 500
            rate_swap::create_offer(true, 10_000, WAD / 20, MATURITY, 500, &clk, scenario.ctx());

            clk.destroy_for_testing();
        };
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = 856)] // EZeroNotional
    fun test_zero_notional() {
        let mut scenario = ts::begin(ALICE);
        {
            let mut clk = clock::create_for_testing(scenario.ctx());
            clk.set_for_testing(1000);
            rate_swap::create_offer(true, 0, WAD / 20, MATURITY, 1_000, &clk, scenario.ctx());
            clk.destroy_for_testing();
        };
        scenario.end();
    }
}
