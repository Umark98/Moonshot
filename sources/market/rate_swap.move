/// Interest Rate Swap contracts for Crux Protocol.
/// Enables pay-fixed/receive-variable (or vice versa) agreements between two parties,
/// allowing hedging of yield exposure. One party locks in a fixed rate while the other
/// receives the variable yield. At settlement, only the net difference is exchanged.
///
/// Flow:
///   1. Offerer calls `create_offer`, specifying whether they pay fixed or variable,
///      the notional amount, agreed fixed rate, maturity, and posts collateral.
///   2. Counterparty calls `accept_offer`, posts matching collateral, and a
///      `SwapContract` shared object is created for both parties.
///   3. At or after maturity, anyone may call `settle_swap` with the realised variable
///      rate to close the contract and record each party's PnL.
module crux::rate_swap {

    use sui::clock::Clock;
    use sui::event;

    use crux::fixed_point;

    // ===== Constants =====

    /// Minimum collateral ratio: 10% of notional (0.1 * WAD)
    const MIN_COLLATERAL_RATIO_WAD: u128 = 100_000_000_000_000_000;

    // ===== Error Codes =====

    /// Swap has already reached (or passed) its maturity timestamp.
    const ESwapExpired: u64 = 850;
    /// Swap has not yet reached maturity; settlement is premature.
    const ESwapNotExpired: u64 = 851;
    /// Swap has already been settled.
    const EAlreadySettled: u64 = 852;
    /// Collateral posted is below the required minimum ratio.
    const EInsufficientCollateral: u64 = 853;
    /// Offer has already been taken by a counterparty.
    const EOfferAlreadyTaken: u64 = 854;
    /// Notional amount must be greater than zero.
    const EZeroNotional: u64 = 856;

    // ===== Structs =====

    /// Shared object representing a single live Interest Rate Swap contract.
    /// Created when an offer is accepted; persists until settled.
    public struct SwapContract has key {
        id: UID,
        /// Pays the fixed rate; receives the variable rate at settlement.
        fixed_rate_payer: address,
        /// Pays the variable rate (i.e. gives up variable yield); receives fixed.
        variable_rate_payer: address,
        /// Reference notional in SY units — no principal changes hands.
        notional_amount: u64,
        /// Agreed fixed rate, WAD-scaled (e.g. 0.05 * WAD = 5% p.a.).
        fixed_rate_wad: u128,
        /// Timestamp (ms) when the contract was created / opened.
        start_ms: u64,
        /// Timestamp (ms) at which the contract matures and may be settled.
        maturity_ms: u64,
        /// Actual variable rate observed at settlement, WAD-scaled.
        /// Zero until `settle_swap` is called.
        settlement_rate_wad: u128,
        /// Whether the contract has been settled.
        is_settled: bool,
        /// Collateral (in SY units) posted by the fixed-rate payer.
        collateral_fixed: u64,
        /// Collateral (in SY units) posted by the variable-rate payer.
        collateral_variable: u64,
    }

    /// Shared object representing an open invitation to enter a swap.
    /// The creator specifies all economic terms and posts collateral upfront.
    /// A counterparty can accept the offer via `accept_offer`.
    public struct SwapOffer has key, store {
        id: UID,
        /// Address that created the offer.
        creator: address,
        /// If true, the creator wishes to pay the fixed rate (receive variable).
        /// If false, the creator wishes to pay variable (receive fixed).
        is_pay_fixed: bool,
        /// Reference notional in SY units.
        notional_amount: u64,
        /// Proposed fixed rate, WAD-scaled.
        fixed_rate_wad: u128,
        /// Desired maturity timestamp (ms).
        maturity_ms: u64,
        /// Collateral posted by the creator.
        collateral_amount: u64,
        /// True once a counterparty has accepted and a SwapContract has been created.
        is_taken: bool,
    }

    // ===== Events =====

    /// Emitted when a new swap offer is published.
    public struct SwapOfferCreated has copy, drop {
        offer_id: ID,
        creator: address,
        is_pay_fixed: bool,
        notional: u64,
        fixed_rate_wad: u128,
        maturity_ms: u64,
    }

    /// Emitted when an offer is matched and a SwapContract is created.
    public struct SwapMatched has copy, drop {
        swap_id: ID,
        fixed_payer: address,
        variable_payer: address,
        notional: u64,
        fixed_rate_wad: u128,
    }

    /// Emitted when a SwapContract is settled.
    public struct SwapSettled has copy, drop {
        swap_id: ID,
        settlement_rate_wad: u128,
        /// Positive means fixed payer gains; negative (stored as 0 here — see pnl sign
        /// convention below) means variable payer gains.
        fixed_payer_pnl: u64,
        variable_payer_pnl: u64,
    }

    // ===== Public Functions =====

    /// Publish an open offer to enter an IRS contract.
    ///
    /// - `is_pay_fixed`: true if the creator wants to pay fixed / receive variable.
    /// - `notional_amount`: reference notional in SY units (must be > 0).
    /// - `fixed_rate_wad`: agreed fixed rate as a WAD fraction (e.g. 5e16 = 5%).
    /// - `maturity_ms`: future timestamp (ms) at which the swap expires.
    /// - `collateral_amount`: SY units posted as collateral. Must be at least
    ///   `notional * MIN_COLLATERAL_RATIO_WAD / WAD`.
    ///
    /// Returns the newly created `SwapOffer` object ID.
    public fun create_offer(
        is_pay_fixed: bool,
        notional_amount: u64,
        fixed_rate_wad: u128,
        maturity_ms: u64,
        collateral_amount: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): ID {
        assert!(notional_amount > 0, EZeroNotional);
        assert!(maturity_ms > clock.timestamp_ms(), ESwapExpired);

        let min_collateral = fixed_point::from_wad(
            fixed_point::wad_mul(
                fixed_point::to_wad(notional_amount),
                MIN_COLLATERAL_RATIO_WAD,
            )
        );
        assert!(collateral_amount >= min_collateral, EInsufficientCollateral);

        let offer = SwapOffer {
            id: object::new(ctx),
            creator: ctx.sender(),
            is_pay_fixed,
            notional_amount,
            fixed_rate_wad,
            maturity_ms,
            collateral_amount,
            is_taken: false,
        };

        let offer_id = object::id(&offer);

        event::emit(SwapOfferCreated {
            offer_id,
            creator: ctx.sender(),
            is_pay_fixed,
            notional: notional_amount,
            fixed_rate_wad,
            maturity_ms,
        });

        transfer::share_object(offer);

        offer_id
    }

    /// Accept an existing swap offer, creating a live `SwapContract`.
    ///
    /// The caller becomes the counterparty: if the offer creator is pay-fixed,
    /// the caller becomes the variable-rate payer, and vice-versa.
    ///
    /// - `collateral_amount`: must meet the same minimum collateral requirement.
    ///
    /// Returns the newly created `SwapContract` object ID.
    public fun accept_offer(
        offer: &mut SwapOffer,
        collateral_amount: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): ID {
        assert!(!offer.is_taken, EOfferAlreadyTaken);
        assert!(clock.timestamp_ms() < offer.maturity_ms, ESwapExpired);

        let min_collateral = fixed_point::from_wad(
            fixed_point::wad_mul(
                fixed_point::to_wad(offer.notional_amount),
                MIN_COLLATERAL_RATIO_WAD,
            )
        );
        assert!(collateral_amount >= min_collateral, EInsufficientCollateral);

        // Mark offer as taken before creating the contract.
        offer.is_taken = true;

        // Determine which role each party takes.
        let (fixed_payer, variable_payer, collateral_fixed, collateral_variable) =
            if (offer.is_pay_fixed) {
                // Creator pays fixed; acceptor pays variable.
                (offer.creator, ctx.sender(), offer.collateral_amount, collateral_amount)
            } else {
                // Creator pays variable; acceptor pays fixed.
                (ctx.sender(), offer.creator, collateral_amount, offer.collateral_amount)
            };

        let swap = SwapContract {
            id: object::new(ctx),
            fixed_rate_payer: fixed_payer,
            variable_rate_payer: variable_payer,
            notional_amount: offer.notional_amount,
            fixed_rate_wad: offer.fixed_rate_wad,
            start_ms: clock.timestamp_ms(),
            maturity_ms: offer.maturity_ms,
            settlement_rate_wad: 0,
            is_settled: false,
            collateral_fixed,
            collateral_variable,
        };

        let swap_id = object::id(&swap);

        event::emit(SwapMatched {
            swap_id,
            fixed_payer,
            variable_payer,
            notional: offer.notional_amount,
            fixed_rate_wad: offer.fixed_rate_wad,
        });

        transfer::share_object(swap);

        swap_id
    }

    /// Settle a matured swap contract.
    ///
    /// Can be called by anyone once `clock.timestamp_ms() >= swap.maturity_ms`.
    /// Computes net PnL for each party:
    ///
    ///   net = (variable_rate - fixed_rate) * notional / WAD
    ///
    /// If `net > 0` the fixed-rate payer profits (variable exceeded fixed);
    /// if `net < 0` the variable-rate payer profits (fixed exceeded variable).
    ///
    /// PnL magnitudes are recorded in the `SwapSettled` event.
    /// Actual collateral transfer is tracked off-chain or via a downstream module.
    public fun settle_swap(
        swap: &mut SwapContract,
        actual_variable_rate_wad: u128,
        clock: &Clock,
    ) {
        assert!(clock.timestamp_ms() >= swap.maturity_ms, ESwapNotExpired);
        assert!(!swap.is_settled, EAlreadySettled);

        swap.settlement_rate_wad = actual_variable_rate_wad;
        swap.is_settled = true;

        // Net settlement amount = |variable_rate - fixed_rate| * notional / WAD
        let (fixed_payer_pnl, variable_payer_pnl) =
            if (actual_variable_rate_wad >= swap.fixed_rate_wad) {
                // Variable exceeded fixed: fixed payer receives the difference.
                let rate_diff = actual_variable_rate_wad - swap.fixed_rate_wad;
                let pnl = fixed_point::from_wad(
                    fixed_point::wad_mul(rate_diff, fixed_point::to_wad(swap.notional_amount))
                );
                (pnl, 0u64)
            } else {
                // Fixed exceeded variable: variable payer receives the difference.
                let rate_diff = swap.fixed_rate_wad - actual_variable_rate_wad;
                let pnl = fixed_point::from_wad(
                    fixed_point::wad_mul(rate_diff, fixed_point::to_wad(swap.notional_amount))
                );
                (0u64, pnl)
            };

        let swap_id = object::id(swap);

        event::emit(SwapSettled {
            swap_id,
            settlement_rate_wad: actual_variable_rate_wad,
            fixed_payer_pnl,
            variable_payer_pnl,
        });
    }

    // ===== View Functions =====

    /// Return the key economic details of a `SwapOffer`.
    /// Returns: (creator, is_pay_fixed, notional_amount, fixed_rate_wad, maturity_ms,
    ///           collateral_amount, is_taken)
    public fun offer_details(offer: &SwapOffer): (address, bool, u64, u128, u64, u64, bool) {
        (
            offer.creator,
            offer.is_pay_fixed,
            offer.notional_amount,
            offer.fixed_rate_wad,
            offer.maturity_ms,
            offer.collateral_amount,
            offer.is_taken,
        )
    }

    /// Return the key details of a `SwapContract`.
    /// Returns: (fixed_rate_payer, variable_rate_payer, notional_amount, fixed_rate_wad,
    ///           start_ms, maturity_ms, settlement_rate_wad, is_settled,
    ///           collateral_fixed, collateral_variable)
    public fun swap_details(swap: &SwapContract): (
        address, address, u64, u128, u64, u64, u128, bool, u64, u64
    ) {
        (
            swap.fixed_rate_payer,
            swap.variable_rate_payer,
            swap.notional_amount,
            swap.fixed_rate_wad,
            swap.start_ms,
            swap.maturity_ms,
            swap.settlement_rate_wad,
            swap.is_settled,
            swap.collateral_fixed,
            swap.collateral_variable,
        )
    }

    /// Return whether a swap contract has been settled.
    public fun is_settled(swap: &SwapContract): bool {
        swap.is_settled
    }
}
