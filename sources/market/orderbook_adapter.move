/// Orderbook Adapter — integrates limit order trading for PT/SY pairs.
/// Designed for future connection to DeepBook v3 (Sui's native CLOB).
///
/// Key features:
///   - Place limit orders for PT ↔ SY trades
///   - Cancel open orders
///   - Track order state (open, filled, cancelled)
///   - Convert between AMM and orderbook pricing
///   - Self-contained order matching for the prototype phase
///
/// When DeepBook v3 integration is available, the internal matching logic
/// can be replaced with direct CLOB calls while preserving the same API.
module crux::orderbook_adapter {

    use sui::clock::Clock;
    use sui::event;

    // ===== Constants =====

    const WAD: u128 = 1_000_000_000_000_000_000;

    // ===== Error Codes =====

    const EOrderNotFound: u64 = 550;
    const EInvalidPrice: u64 = 552;
    const EZeroAmount: u64 = 553;
    const ENotOrderOwner: u64 = 554;
    const EBookNotActive: u64 = 555;
    const EBookExpired: u64 = 556;

    // ===== Order Side =====

    const BUY_PT: u8 = 0;
    const SELL_PT: u8 = 1;

    // ===== Structs =====

    /// Shared object: an orderbook for a specific (underlying, maturity) pair.
    /// Tracks all open limit orders for PT ↔ SY trading.
    public struct OrderBook has key {
        id: UID,
        /// Reference to the YieldMarketConfig this book serves
        market_config_id: ID,
        /// Maturity timestamp (ms) — orders are invalid past this point
        maturity_ms: u64,
        /// All orders (open, filled, cancelled) stored in insertion order
        orders: vector<Order>,
        /// Monotonically increasing order ID counter
        next_order_id: u64,
        /// Whether the book accepts new orders
        is_active: bool,
    }

    /// A single limit order on the book.
    public struct Order has store, drop, copy {
        /// Unique identifier within this OrderBook
        order_id: u64,
        /// Address that placed the order
        owner: address,
        /// BUY_PT (0) or SELL_PT (1)
        side: u8,
        /// PT price denominated in SY, WAD-scaled (e.g., 0.95 * WAD)
        price_wad: u128,
        /// Total PT amount for this order
        pt_amount: u64,
        /// Amount of PT already filled
        filled_amount: u64,
        /// Timestamp when order was placed (ms)
        timestamp_ms: u64,
        /// Whether the order has been cancelled
        is_cancelled: bool,
    }

    // ===== Events =====

    public struct OrderPlaced has copy, drop {
        book_id: ID,
        order_id: u64,
        owner: address,
        side: u8,
        price_wad: u128,
        pt_amount: u64,
        timestamp_ms: u64,
    }

    public struct OrderCancelled has copy, drop {
        book_id: ID,
        order_id: u64,
        owner: address,
        unfilled_amount: u64,
    }

    public struct OrderFilled has copy, drop {
        book_id: ID,
        order_id: u64,
        filled_amount: u64,
        remaining_amount: u64,
        fill_price_wad: u128,
    }

    // ===== OrderBook Creation =====

    /// Create a new orderbook for a (underlying, maturity) pair.
    /// Returns the ID of the newly created shared OrderBook object.
    public fun create_orderbook(
        market_config_id: ID,
        maturity_ms: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): ID {
        assert!(clock.timestamp_ms() < maturity_ms, EBookExpired);

        let book = OrderBook {
            id: object::new(ctx),
            market_config_id,
            maturity_ms,
            orders: vector[],
            next_order_id: 0,
            is_active: true,
        };

        let book_id = object::id(&book);
        transfer::share_object(book);
        book_id
    }

    // ===== Order Placement =====

    /// Place a limit order on the book.
    /// `side`: BUY_PT (0) to buy PT with SY, or SELL_PT (1) to sell PT for SY.
    /// `price_wad`: PT price in SY terms, WAD-scaled. Must be in (0, WAD].
    /// `pt_amount`: Amount of PT to buy or sell.
    /// Returns the assigned order_id.
    public fun place_order(
        book: &mut OrderBook,
        side: u8,
        price_wad: u128,
        pt_amount: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): u64 {
        assert!(book.is_active, EBookNotActive);
        let now = clock.timestamp_ms();
        assert!(now < book.maturity_ms, EBookExpired);
        assert!(pt_amount > 0, EZeroAmount);
        assert!(price_wad > 0 && price_wad <= WAD, EInvalidPrice);
        assert!(side == BUY_PT || side == SELL_PT, EInvalidPrice);

        let order_id = book.next_order_id;
        book.next_order_id = order_id + 1;

        let order = Order {
            order_id,
            owner: ctx.sender(),
            side,
            price_wad,
            pt_amount,
            filled_amount: 0,
            timestamp_ms: now,
            is_cancelled: false,
        };

        book.orders.push_back(order);

        let book_id = object::id(book);
        event::emit(OrderPlaced {
            book_id,
            order_id,
            owner: ctx.sender(),
            side,
            price_wad,
            pt_amount,
            timestamp_ms: now,
        });

        order_id
    }

    // ===== Order Cancellation =====

    /// Cancel an open order. Only the order owner may cancel.
    /// Aborts if the order is not found, already fully filled, or not owned by sender.
    public fun cancel_order(
        book: &mut OrderBook,
        order_id: u64,
        ctx: &mut TxContext,
    ) {
        let (found, idx) = find_order_index(book, order_id);
        assert!(found, EOrderNotFound);

        let order = &mut book.orders[idx];
        assert!(order.owner == ctx.sender(), ENotOrderOwner);
        assert!(!order.is_cancelled, EOrderNotFound);

        order.is_cancelled = true;
        let unfilled = order.pt_amount - order.filled_amount;

        let book_id = object::id(book);
        event::emit(OrderCancelled {
            book_id,
            order_id,
            owner: ctx.sender(),
            unfilled_amount: unfilled,
        });
    }

    // ===== Order Filling (internal matching) =====

    /// Fill an order by the specified amount. This is the internal matching entry point.
    /// In a future DeepBook integration, this would be triggered by the CLOB engine.
    /// Returns the SY cost/proceeds of the fill (WAD-scaled amount converted to u64).
    public fun fill_order(
        book: &mut OrderBook,
        order_id: u64,
        fill_pt_amount: u64,
        clock: &Clock,
    ): u64 {
        let now = clock.timestamp_ms();
        assert!(now < book.maturity_ms, EBookExpired);

        let (found, idx) = find_order_index(book, order_id);
        assert!(found, EOrderNotFound);

        // Get book_id before taking mutable borrow on orders
        let book_id = object::id(book);

        let order = &mut book.orders[idx];
        assert!(!order.is_cancelled, EOrderNotFound);

        let remaining = order.pt_amount - order.filled_amount;
        assert!(remaining > 0, EOrderNotFound);

        // Clamp fill amount to remaining
        let actual_fill = if (fill_pt_amount > remaining) { remaining } else { fill_pt_amount };
        assert!(actual_fill > 0, EZeroAmount);

        order.filled_amount = order.filled_amount + actual_fill;
        let new_remaining = order.pt_amount - order.filled_amount;

        // Calculate SY equivalent: sy_amount = pt_amount * price_wad / WAD
        let sy_amount = ((actual_fill as u128) * order.price_wad / WAD as u64);

        event::emit(OrderFilled {
            book_id,
            order_id,
            filled_amount: actual_fill,
            remaining_amount: new_remaining,
            fill_price_wad: order.price_wad,
        });

        sy_amount
    }

    // ===== View Functions =====

    /// Get a copy of an order by its ID. Aborts if not found.
    public fun get_order(book: &OrderBook, order_id: u64): Order {
        let (found, idx) = find_order_index(book, order_id);
        assert!(found, EOrderNotFound);
        book.orders[idx]
    }

    /// Get the best (highest price) active bid (BUY_PT) on the book.
    /// Returns (price_wad, order_id). Aborts if no active bids exist.
    public fun best_bid(book: &OrderBook, clock: &Clock): (u128, u64) {
        let now = clock.timestamp_ms();
        let mut best_price: u128 = 0;
        let mut best_id: u64 = 0;
        let mut found = false;

        let mut i = 0u64;
        let len = book.orders.length();
        while (i < len) {
            let order = &book.orders[i];
            if (order.side == BUY_PT
                && !order.is_cancelled
                && order.filled_amount < order.pt_amount
                && order.timestamp_ms <= now)
            {
                if (!found || order.price_wad > best_price) {
                    best_price = order.price_wad;
                    best_id = order.order_id;
                    found = true;
                };
            };
            i = i + 1;
        };

        assert!(found, EOrderNotFound);
        (best_price, best_id)
    }

    /// Get the best (lowest price) active ask (SELL_PT) on the book.
    /// Returns (price_wad, order_id). Aborts if no active asks exist.
    public fun best_ask(book: &OrderBook, clock: &Clock): (u128, u64) {
        let now = clock.timestamp_ms();
        let mut best_price: u128 = WAD + 1; // sentinel above max valid price
        let mut best_id: u64 = 0;
        let mut found = false;

        let mut i = 0u64;
        let len = book.orders.length();
        while (i < len) {
            let order = &book.orders[i];
            if (order.side == SELL_PT
                && !order.is_cancelled
                && order.filled_amount < order.pt_amount
                && order.timestamp_ms <= now)
            {
                if (!found || order.price_wad < best_price) {
                    best_price = order.price_wad;
                    best_id = order.order_id;
                    found = true;
                };
            };
            i = i + 1;
        };

        assert!(found, EOrderNotFound);
        (best_price, best_id)
    }

    /// Count the number of active (open, unfilled or partially filled) orders.
    public fun order_count(book: &OrderBook): u64 {
        let mut count = 0u64;
        let mut i = 0u64;
        let len = book.orders.length();
        while (i < len) {
            let order = &book.orders[i];
            if (!order.is_cancelled && order.filled_amount < order.pt_amount) {
                count = count + 1;
            };
            i = i + 1;
        };
        count
    }

    /// Get the spread (best_ask - best_bid) in WAD. Returns 0 if either side is empty.
    public fun spread_wad(book: &OrderBook, clock: &Clock): u128 {
        let bid_result = try_best_bid(book, clock);
        let ask_result = try_best_ask(book, clock);

        if (bid_result == 0 || ask_result == 0) return 0;
        if (ask_result > bid_result) {
            ask_result - bid_result
        } else {
            0
        }
    }

    /// Get the orderbook's market config ID.
    public fun book_market_config_id(book: &OrderBook): ID {
        book.market_config_id
    }

    /// Get the orderbook's maturity timestamp.
    public fun book_maturity(book: &OrderBook): u64 {
        book.maturity_ms
    }

    /// Check whether the book is active.
    public fun is_active(book: &OrderBook): bool {
        book.is_active
    }

    /// Get the order's owner address.
    public fun order_owner(order: &Order): address {
        order.owner
    }

    /// Get the order's side (BUY_PT or SELL_PT).
    public fun order_side(order: &Order): u8 {
        order.side
    }

    /// Get the order's price in WAD.
    public fun order_price(order: &Order): u128 {
        order.price_wad
    }

    /// Get the order's total PT amount.
    public fun order_pt_amount(order: &Order): u64 {
        order.pt_amount
    }

    /// Get the order's filled amount.
    public fun order_filled(order: &Order): u64 {
        order.filled_amount
    }

    /// Check if the order is fully filled.
    public fun is_fully_filled(order: &Order): bool {
        order.filled_amount >= order.pt_amount
    }

    /// Check if the order is cancelled.
    public fun is_cancelled(order: &Order): bool {
        order.is_cancelled
    }

    // ===== Admin Functions =====

    /// Deactivate the orderbook (e.g., at maturity or for migration).
    /// After deactivation, no new orders can be placed.
    public fun deactivate_book(book: &mut OrderBook, clock: &Clock) {
        let _ = clock.timestamp_ms();
        book.is_active = false;
    }

    // ===== Internal Helpers =====

    /// Find the vector index of an order by order_id.
    /// Returns (found, index). If not found, index is 0.
    fun find_order_index(book: &OrderBook, order_id: u64): (bool, u64) {
        let mut i = 0u64;
        let len = book.orders.length();
        while (i < len) {
            if (book.orders[i].order_id == order_id) {
                return (true, i)
            };
            i = i + 1;
        };
        (false, 0)
    }

    /// Try to get the best bid price. Returns 0 if no active bids.
    fun try_best_bid(book: &OrderBook, clock: &Clock): u128 {
        let now = clock.timestamp_ms();
        let mut best_price: u128 = 0;

        let mut i = 0u64;
        let len = book.orders.length();
        while (i < len) {
            let order = &book.orders[i];
            if (order.side == BUY_PT
                && !order.is_cancelled
                && order.filled_amount < order.pt_amount
                && order.timestamp_ms <= now
                && order.price_wad > best_price)
            {
                best_price = order.price_wad;
            };
            i = i + 1;
        };

        best_price
    }

    /// Try to get the best ask price. Returns 0 if no active asks.
    fun try_best_ask(book: &OrderBook, clock: &Clock): u128 {
        let now = clock.timestamp_ms();
        let mut best_price: u128 = 0;
        let mut first = true;

        let mut i = 0u64;
        let len = book.orders.length();
        while (i < len) {
            let order = &book.orders[i];
            if (order.side == SELL_PT
                && !order.is_cancelled
                && order.filled_amount < order.pt_amount
                && order.timestamp_ms <= now)
            {
                if (first || order.price_wad < best_price) {
                    best_price = order.price_wad;
                    first = false;
                };
            };
            i = i + 1;
        };

        best_price
    }
}
