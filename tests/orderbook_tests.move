#[test_only]
module crux::orderbook_tests {
    use sui::test_scenario::{Self as ts};
    use sui::clock;

    use crux::orderbook_adapter::{Self, OrderBook};

    const ADMIN: address = @0xAD;
    const USER1: address = @0xB0B;
    const USER2: address = @0xCAFE;

    const WAD: u128 = 1_000_000_000_000_000_000;
    const BUY_PT: u8 = 0;
    const SELL_PT: u8 = 1;

    fun setup(): ts::Scenario {
        let mut scenario = ts::begin(ADMIN);
        {
            let mut clock = clock::create_for_testing(scenario.ctx());
            clock.set_for_testing(1000); // 1 second
            let market_id = object::id_from_address(@0x1);
            let maturity_ms = 100_000_000; // far future
            orderbook_adapter::create_orderbook(market_id, maturity_ms, &clock, scenario.ctx());
            clock.destroy_for_testing();
        };
        scenario
    }

    #[test]
    fun test_create_orderbook() {
        let mut scenario = setup();

        scenario.next_tx(ADMIN);
        {
            let book = scenario.take_shared<OrderBook>();
            assert!(orderbook_adapter::is_active(&book));
            assert!(orderbook_adapter::order_count(&book) == 0);
            ts::return_shared(book);
        };
        scenario.end();
    }

    #[test]
    fun test_place_buy_order() {
        let mut scenario = setup();

        scenario.next_tx(USER1);
        {
            let mut book = scenario.take_shared<OrderBook>();
            let mut clock = clock::create_for_testing(scenario.ctx());
            clock.set_for_testing(2000);

            let price = 950_000_000_000_000_000; // 0.95 WAD
            let order_id = orderbook_adapter::place_order(
                &mut book, BUY_PT, price, 1000, &clock, scenario.ctx(),
            );

            assert!(order_id == 0);
            assert!(orderbook_adapter::order_count(&book) == 1);

            let order = orderbook_adapter::get_order(&book, 0);
            assert!(orderbook_adapter::order_owner(&order) == USER1);
            assert!(orderbook_adapter::order_side(&order) == BUY_PT);
            assert!(orderbook_adapter::order_price(&order) == price);
            assert!(orderbook_adapter::order_pt_amount(&order) == 1000);
            assert!(orderbook_adapter::order_filled(&order) == 0);
            assert!(!orderbook_adapter::is_fully_filled(&order));
            assert!(!orderbook_adapter::is_cancelled(&order));

            clock.destroy_for_testing();
            ts::return_shared(book);
        };
        scenario.end();
    }

    #[test]
    fun test_place_sell_order() {
        let mut scenario = setup();

        scenario.next_tx(USER1);
        {
            let mut book = scenario.take_shared<OrderBook>();
            let mut clock = clock::create_for_testing(scenario.ctx());
            clock.set_for_testing(2000);

            let price = 970_000_000_000_000_000; // 0.97 WAD
            let order_id = orderbook_adapter::place_order(
                &mut book, SELL_PT, price, 500, &clock, scenario.ctx(),
            );

            assert!(order_id == 0);
            let order = orderbook_adapter::get_order(&book, 0);
            assert!(orderbook_adapter::order_side(&order) == SELL_PT);

            clock.destroy_for_testing();
            ts::return_shared(book);
        };
        scenario.end();
    }

    #[test]
    fun test_cancel_order() {
        let mut scenario = setup();

        // Place order
        scenario.next_tx(USER1);
        {
            let mut book = scenario.take_shared<OrderBook>();
            let mut clock = clock::create_for_testing(scenario.ctx());
            clock.set_for_testing(2000);
            orderbook_adapter::place_order(
                &mut book, BUY_PT, 950_000_000_000_000_000, 1000, &clock, scenario.ctx(),
            );
            clock.destroy_for_testing();
            ts::return_shared(book);
        };

        // Cancel order
        scenario.next_tx(USER1);
        {
            let mut book = scenario.take_shared<OrderBook>();
            orderbook_adapter::cancel_order(&mut book, 0, scenario.ctx());

            let order = orderbook_adapter::get_order(&book, 0);
            assert!(orderbook_adapter::is_cancelled(&order));
            assert!(orderbook_adapter::order_count(&book) == 0); // cancelled orders not counted

            ts::return_shared(book);
        };
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = 554)] // ENotOrderOwner
    fun test_cancel_not_owner() {
        let mut scenario = setup();

        // Place order as USER1
        scenario.next_tx(USER1);
        {
            let mut book = scenario.take_shared<OrderBook>();
            let mut clock = clock::create_for_testing(scenario.ctx());
            clock.set_for_testing(2000);
            orderbook_adapter::place_order(
                &mut book, BUY_PT, 950_000_000_000_000_000, 1000, &clock, scenario.ctx(),
            );
            clock.destroy_for_testing();
            ts::return_shared(book);
        };

        // USER2 tries to cancel — should fail
        scenario.next_tx(USER2);
        {
            let mut book = scenario.take_shared<OrderBook>();
            orderbook_adapter::cancel_order(&mut book, 0, scenario.ctx());
            ts::return_shared(book);
        };
        scenario.end();
    }

    #[test]
    fun test_fill_order() {
        let mut scenario = setup();

        // Place order
        scenario.next_tx(USER1);
        {
            let mut book = scenario.take_shared<OrderBook>();
            let mut clock = clock::create_for_testing(scenario.ctx());
            clock.set_for_testing(2000);
            orderbook_adapter::place_order(
                &mut book, BUY_PT, 950_000_000_000_000_000, 1000, &clock, scenario.ctx(),
            );
            clock.destroy_for_testing();
            ts::return_shared(book);
        };

        // Fill order partially
        scenario.next_tx(ADMIN);
        {
            let mut book = scenario.take_shared<OrderBook>();
            let mut clock = clock::create_for_testing(scenario.ctx());
            clock.set_for_testing(3000);

            let sy_amount = orderbook_adapter::fill_order(&mut book, 0, 500, &clock);
            assert!(sy_amount > 0);

            let order = orderbook_adapter::get_order(&book, 0);
            assert!(orderbook_adapter::order_filled(&order) == 500);
            assert!(!orderbook_adapter::is_fully_filled(&order));
            assert!(orderbook_adapter::order_count(&book) == 1); // still active

            clock.destroy_for_testing();
            ts::return_shared(book);
        };

        // Fill rest
        scenario.next_tx(ADMIN);
        {
            let mut book = scenario.take_shared<OrderBook>();
            let mut clock = clock::create_for_testing(scenario.ctx());
            clock.set_for_testing(4000);

            orderbook_adapter::fill_order(&mut book, 0, 500, &clock);

            let order = orderbook_adapter::get_order(&book, 0);
            assert!(orderbook_adapter::order_filled(&order) == 1000);
            assert!(orderbook_adapter::is_fully_filled(&order));
            assert!(orderbook_adapter::order_count(&book) == 0); // fully filled

            clock.destroy_for_testing();
            ts::return_shared(book);
        };
        scenario.end();
    }

    #[test]
    fun test_best_bid_ask() {
        let mut scenario = setup();

        scenario.next_tx(USER1);
        {
            let mut book = scenario.take_shared<OrderBook>();
            let mut clock = clock::create_for_testing(scenario.ctx());
            clock.set_for_testing(2000);

            // Place bids
            orderbook_adapter::place_order(
                &mut book, BUY_PT, 940_000_000_000_000_000, 100, &clock, scenario.ctx(),
            );
            orderbook_adapter::place_order(
                &mut book, BUY_PT, 960_000_000_000_000_000, 200, &clock, scenario.ctx(),
            );
            orderbook_adapter::place_order(
                &mut book, BUY_PT, 950_000_000_000_000_000, 150, &clock, scenario.ctx(),
            );

            // Place asks
            orderbook_adapter::place_order(
                &mut book, SELL_PT, 980_000_000_000_000_000, 100, &clock, scenario.ctx(),
            );
            orderbook_adapter::place_order(
                &mut book, SELL_PT, 970_000_000_000_000_000, 200, &clock, scenario.ctx(),
            );

            // Best bid = highest buy price
            let (best_bid_price, best_bid_id) = orderbook_adapter::best_bid(&book, &clock);
            assert!(best_bid_price == 960_000_000_000_000_000);
            assert!(best_bid_id == 1);

            // Best ask = lowest sell price
            let (best_ask_price, best_ask_id) = orderbook_adapter::best_ask(&book, &clock);
            assert!(best_ask_price == 970_000_000_000_000_000);
            assert!(best_ask_id == 4);

            // Spread = best_ask - best_bid = 0.01
            let spread = orderbook_adapter::spread_wad(&book, &clock);
            assert!(spread == 10_000_000_000_000_000);

            clock.destroy_for_testing();
            ts::return_shared(book);
        };
        scenario.end();
    }

    #[test]
    fun test_multiple_orders_count() {
        let mut scenario = setup();

        scenario.next_tx(USER1);
        {
            let mut book = scenario.take_shared<OrderBook>();
            let mut clock = clock::create_for_testing(scenario.ctx());
            clock.set_for_testing(2000);

            orderbook_adapter::place_order(
                &mut book, BUY_PT, 950_000_000_000_000_000, 100, &clock, scenario.ctx(),
            );
            orderbook_adapter::place_order(
                &mut book, SELL_PT, 970_000_000_000_000_000, 200, &clock, scenario.ctx(),
            );
            orderbook_adapter::place_order(
                &mut book, BUY_PT, 940_000_000_000_000_000, 300, &clock, scenario.ctx(),
            );

            assert!(orderbook_adapter::order_count(&book) == 3);

            clock.destroy_for_testing();
            ts::return_shared(book);
        };
        scenario.end();
    }

    #[test]
    fun test_deactivate_book() {
        let mut scenario = setup();

        scenario.next_tx(ADMIN);
        {
            let mut book = scenario.take_shared<OrderBook>();
            let clock = clock::create_for_testing(scenario.ctx());

            orderbook_adapter::deactivate_book(&mut book, &clock);
            assert!(!orderbook_adapter::is_active(&book));

            clock.destroy_for_testing();
            ts::return_shared(book);
        };
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = 555)] // EBookNotActive
    fun test_place_order_inactive_book() {
        let mut scenario = setup();

        // Deactivate
        scenario.next_tx(ADMIN);
        {
            let mut book = scenario.take_shared<OrderBook>();
            let clock = clock::create_for_testing(scenario.ctx());
            orderbook_adapter::deactivate_book(&mut book, &clock);
            clock.destroy_for_testing();
            ts::return_shared(book);
        };

        // Try placing order — should fail
        scenario.next_tx(USER1);
        {
            let mut book = scenario.take_shared<OrderBook>();
            let mut clock = clock::create_for_testing(scenario.ctx());
            clock.set_for_testing(2000);
            orderbook_adapter::place_order(
                &mut book, BUY_PT, 950_000_000_000_000_000, 100, &clock, scenario.ctx(),
            );
            clock.destroy_for_testing();
            ts::return_shared(book);
        };
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = 553)] // EZeroAmount
    fun test_place_zero_amount() {
        let mut scenario = setup();

        scenario.next_tx(USER1);
        {
            let mut book = scenario.take_shared<OrderBook>();
            let mut clock = clock::create_for_testing(scenario.ctx());
            clock.set_for_testing(2000);
            orderbook_adapter::place_order(
                &mut book, BUY_PT, 950_000_000_000_000_000, 0, &clock, scenario.ctx(),
            );
            clock.destroy_for_testing();
            ts::return_shared(book);
        };
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = 552)] // EInvalidPrice
    fun test_place_zero_price() {
        let mut scenario = setup();

        scenario.next_tx(USER1);
        {
            let mut book = scenario.take_shared<OrderBook>();
            let mut clock = clock::create_for_testing(scenario.ctx());
            clock.set_for_testing(2000);
            orderbook_adapter::place_order(
                &mut book, BUY_PT, 0, 1000, &clock, scenario.ctx(),
            );
            clock.destroy_for_testing();
            ts::return_shared(book);
        };
        scenario.end();
    }

    #[test]
    fun test_fill_clamp_to_remaining() {
        let mut scenario = setup();

        // Place order for 100
        scenario.next_tx(USER1);
        {
            let mut book = scenario.take_shared<OrderBook>();
            let mut clock = clock::create_for_testing(scenario.ctx());
            clock.set_for_testing(2000);
            orderbook_adapter::place_order(
                &mut book, BUY_PT, 950_000_000_000_000_000, 100, &clock, scenario.ctx(),
            );
            clock.destroy_for_testing();
            ts::return_shared(book);
        };

        // Try to fill 200 — should clamp to 100
        scenario.next_tx(ADMIN);
        {
            let mut book = scenario.take_shared<OrderBook>();
            let mut clock = clock::create_for_testing(scenario.ctx());
            clock.set_for_testing(3000);

            orderbook_adapter::fill_order(&mut book, 0, 200, &clock);

            let order = orderbook_adapter::get_order(&book, 0);
            assert!(orderbook_adapter::order_filled(&order) == 100);
            assert!(orderbook_adapter::is_fully_filled(&order));

            clock.destroy_for_testing();
            ts::return_shared(book);
        };
        scenario.end();
    }
}
