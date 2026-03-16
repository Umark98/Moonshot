/// AMM math for Crux's yield market.
/// Implements a LogitNormal-inspired curve optimized for interest rate trading.
module crux::amm_math {

    use crux::fixed_point;

    // ===== Constants =====

    /// Milliseconds per year
    const MS_PER_YEAR: u128 = 31_557_600_000;

    /// WAD constant (1e18)
    const WAD: u128 = 1_000_000_000_000_000_000;

    /// Minimum time to maturity to prevent division by near-zero (1 hour in ms)
    const MIN_TIME_TO_MATURITY_MS: u64 = 3_600_000;

    // ===== Error Codes =====

    const EInvalidTimeToMaturity: u64 = 100;
    const EInvalidImpliedRate: u64 = 101;
    const EInsufficientLiquidity: u64 = 102;
    const EInvalidReserves: u64 = 104;

    // ===== Core Pricing Functions =====

    /// Calculate the PT price in SY terms given an implied annual rate and time to maturity.
    /// pt_price = 1 / (1 + rate)^(time_to_maturity / year)
    public fun pt_price_from_rate(
        implied_rate_wad: u128,
        time_to_maturity_ms: u64,
    ): u128 {
        assert!(time_to_maturity_ms >= MIN_TIME_TO_MATURITY_MS, EInvalidTimeToMaturity);

        let time_fraction = fixed_point::wad_div(
            (time_to_maturity_ms as u128) * WAD,
            MS_PER_YEAR * WAD,
        );

        let one_plus_rate = WAD + implied_rate_wad;
        let ln_one_plus_rate = fixed_point::wad_ln(one_plus_rate);
        let exponent = fixed_point::wad_mul(time_fraction, ln_one_plus_rate);
        let compound = fixed_point::wad_exp(exponent);

        fixed_point::wad_div(WAD, compound)
    }

    /// Calculate the implied annual rate from a PT price and time to maturity.
    public fun rate_from_pt_price(
        pt_price_wad: u128,
        time_to_maturity_ms: u64,
    ): u128 {
        assert!(time_to_maturity_ms >= MIN_TIME_TO_MATURITY_MS, EInvalidTimeToMaturity);
        assert!(pt_price_wad > 0 && pt_price_wad <= WAD, EInvalidImpliedRate);

        if (pt_price_wad == WAD) return 0;

        let time_fraction = fixed_point::wad_div(
            (time_to_maturity_ms as u128) * WAD,
            MS_PER_YEAR * WAD,
        );

        let inv_price = fixed_point::wad_div(WAD, pt_price_wad);
        let ln_inv = fixed_point::wad_ln(inv_price);
        let rate_ln = fixed_point::wad_div(ln_inv, time_fraction);
        let compound = fixed_point::wad_exp(rate_ln);

        if (compound > WAD) {
            compound - WAD
        } else {
            0
        }
    }

    /// YT price = 1 - PT price
    public fun yt_price_from_pt_price(pt_price_wad: u128): u128 {
        if (pt_price_wad >= WAD) { 0 } else { WAD - pt_price_wad }
    }

    /// YT leverage = 1 / yt_price
    public fun yt_leverage(pt_price_wad: u128): u128 {
        let yt_price = yt_price_from_pt_price(pt_price_wad);
        if (yt_price == 0) return 0;
        fixed_point::wad_div(WAD, yt_price)
    }

    // ===== AMM Swap Math =====

    /// Calculate output for PT → SY swap.
    public fun calc_swap_pt_for_sy(
        pt_reserve: u64,
        sy_reserve: u64,
        pt_in: u64,
        fee_rate_wad: u128,
        scalar_root: u128,
        time_to_maturity_ms: u64,
        total_duration_ms: u64,
    ): u64 {
        assert!(pt_reserve > 0 && sy_reserve > 0, EInsufficientLiquidity);
        assert!(pt_in > 0, EInvalidReserves);

        let pt_res = (pt_reserve as u128);
        let sy_res = (sy_reserve as u128);
        let dx = (pt_in as u128);

        let time_weight = if (total_duration_ms > 0) {
            let remaining = fixed_point::wad_div(
                (time_to_maturity_ms as u128) * WAD,
                (total_duration_ms as u128) * WAD,
            );
            fixed_point::wad_mul(remaining, scalar_root)
        } else {
            0
        };

        let k = pt_res * sy_res;
        let new_pt_reserve = pt_res + dx;
        let new_sy_reserve = k / new_pt_reserve;
        let base_dy = sy_res - new_sy_reserve;

        let time_adjusted_dy = if (time_weight > 0) {
            let amm_weight = fixed_point::min_u128(time_weight, WAD);
            let par_weight = WAD - amm_weight;
            let amm_component = fixed_point::wad_mul(base_dy * WAD, amm_weight) / WAD;
            let par_component = fixed_point::wad_mul(dx * WAD, par_weight) / WAD;
            amm_component + par_component
        } else {
            dx
        };

        let fee = fixed_point::wad_mul(time_adjusted_dy * WAD, fee_rate_wad) / WAD;
        let dy_after_fee = time_adjusted_dy - fee;

        let output = fixed_point::min_u128(dy_after_fee, sy_res - 1);
        (output as u64)
    }

    /// Calculate output for SY → PT swap.
    public fun calc_swap_sy_for_pt(
        pt_reserve: u64,
        sy_reserve: u64,
        sy_in: u64,
        fee_rate_wad: u128,
        scalar_root: u128,
        time_to_maturity_ms: u64,
        total_duration_ms: u64,
    ): u64 {
        assert!(pt_reserve > 0 && sy_reserve > 0, EInsufficientLiquidity);
        assert!(sy_in > 0, EInvalidReserves);

        let pt_res = (pt_reserve as u128);
        let sy_res = (sy_reserve as u128);
        let dx = (sy_in as u128);

        let time_weight = if (total_duration_ms > 0) {
            let remaining = fixed_point::wad_div(
                (time_to_maturity_ms as u128) * WAD,
                (total_duration_ms as u128) * WAD,
            );
            fixed_point::wad_mul(remaining, scalar_root)
        } else {
            0
        };

        let k = pt_res * sy_res;
        let new_sy_reserve = sy_res + dx;
        let new_pt_reserve = k / new_sy_reserve;
        let base_dy = pt_res - new_pt_reserve;

        let time_adjusted_dy = if (time_weight > 0) {
            let amm_weight = fixed_point::min_u128(time_weight, WAD);
            let par_weight = WAD - amm_weight;
            let amm_component = fixed_point::wad_mul(base_dy * WAD, amm_weight) / WAD;
            let par_component = fixed_point::wad_mul(dx * WAD, par_weight) / WAD;
            amm_component + par_component
        } else {
            dx
        };

        let fee = fixed_point::wad_mul(time_adjusted_dy * WAD, fee_rate_wad) / WAD;
        let dy_after_fee = time_adjusted_dy - fee;

        let output = fixed_point::min_u128(dy_after_fee, pt_res - 1);
        (output as u64)
    }

    // ===== Liquidity Math =====

    /// Calculate LP tokens to mint.
    public fun calc_lp_tokens_to_mint(
        pt_deposit: u64,
        sy_deposit: u64,
        pt_reserve: u64,
        sy_reserve: u64,
        total_lp_supply: u64,
    ): u64 {
        if (total_lp_supply == 0) {
            let product = (pt_deposit as u128) * (sy_deposit as u128);
            (sqrt_u128(product) as u64)
        } else {
            let pt_ratio = fixed_point::wad_div(
                (pt_deposit as u128) * WAD,
                (pt_reserve as u128) * WAD,
            );
            let sy_ratio = fixed_point::wad_div(
                (sy_deposit as u128) * WAD,
                (sy_reserve as u128) * WAD,
            );
            let ratio = fixed_point::min_u128(pt_ratio, sy_ratio);
            let lp_amount = fixed_point::wad_mul(ratio, (total_lp_supply as u128) * WAD) / WAD;
            (lp_amount as u64)
        }
    }

    /// Calculate PT and SY amounts to return for LP token burn.
    public fun calc_withdraw_amounts(
        lp_burn: u64,
        pt_reserve: u64,
        sy_reserve: u64,
        total_lp_supply: u64,
    ): (u64, u64) {
        assert!(total_lp_supply > 0, EInsufficientLiquidity);
        let share = fixed_point::wad_div(
            (lp_burn as u128) * WAD,
            (total_lp_supply as u128) * WAD,
        );
        let pt_out = fixed_point::wad_mul(share, (pt_reserve as u128) * WAD) / WAD;
        let sy_out = fixed_point::wad_mul(share, (sy_reserve as u128) * WAD) / WAD;
        ((pt_out as u64), (sy_out as u64))
    }

    // ===== TWAP Oracle Math =====

    /// Calculate the cumulative rate value for TWAP.
    /// Cumulative = sum of (ln(1 + rate) * dt_ms). Units: WAD·ms.
    /// Dividing a delta of cumulatives by elapsed ms yields a WAD-scaled ln(1+rate).
    public fun calc_cumulative_rate(
        prev_cumulative: u128,
        implied_rate_wad: u128,
        time_elapsed_ms: u64,
    ): u128 {
        let ln_rate = fixed_point::wad_ln(WAD + implied_rate_wad);
        let increment = ln_rate * (time_elapsed_ms as u128);
        prev_cumulative + increment
    }

    /// Calculate TWAP implied rate from two cumulative observations.
    public fun calc_twap_rate(
        cumulative_start: u128,
        cumulative_end: u128,
        time_elapsed_ms: u64,
    ): u128 {
        if (time_elapsed_ms == 0) return 0;
        let avg_ln_rate = (cumulative_end - cumulative_start) / (time_elapsed_ms as u128);
        let compound = fixed_point::wad_exp(avg_ln_rate);
        if (compound > WAD) { compound - WAD } else { 0 }
    }

    // ===== Utility =====

    /// Integer square root using Newton's method
    fun sqrt_u128(x: u128): u128 {
        if (x == 0) return 0;
        if (x <= 3) return 1;

        let mut z = x;
        let mut y = (x + 1) / 2;

        while (y < z) {
            z = y;
            y = (x / y + y) / 2;
        };

        z
    }

    // ===== Tests =====

    #[test]
    fun test_pt_price_from_rate() {
        let rate = 70_000_000_000_000_000; // 7%
        let time_ms: u64 = 15_778_800_000; // ~6 months
        let price = pt_price_from_rate(rate, time_ms);
        assert!(price > 960_000_000_000_000_000 && price < 975_000_000_000_000_000);
    }

    #[test]
    fun test_rate_from_pt_price() {
        let price = 966_000_000_000_000_000; // 0.966
        let time_ms: u64 = 15_778_800_000;
        let rate = rate_from_pt_price(price, time_ms);
        assert!(rate > 60_000_000_000_000_000 && rate < 80_000_000_000_000_000);
    }

    #[test]
    fun test_yt_price() {
        let pt_price = 966_000_000_000_000_000;
        let yt_price = yt_price_from_pt_price(pt_price);
        assert!(yt_price == 34_000_000_000_000_000);
    }

    #[test]
    fun test_yt_leverage() {
        let pt_price = 966_000_000_000_000_000;
        let leverage = yt_leverage(pt_price);
        assert!(leverage > 29 * WAD && leverage < 30 * WAD);
    }

    #[test]
    fun test_swap_symmetry() {
        let pt_res: u64 = 1_000_000_000;
        let sy_res: u64 = 1_000_000_000;
        let fee = 3_000_000_000_000_000; // 0.3%
        let scalar = WAD;
        let time_ms: u64 = 15_778_800_000;
        let total_ms: u64 = 31_557_600_000;

        let sy_out = calc_swap_pt_for_sy(pt_res, sy_res, 1_000_000, fee, scalar, time_ms, total_ms);
        assert!(sy_out > 0 && sy_out < 1_000_000);
    }

    #[test]
    fun test_sqrt() {
        assert!(sqrt_u128(0) == 0);
        assert!(sqrt_u128(1) == 1);
        assert!(sqrt_u128(4) == 2);
        assert!(sqrt_u128(9) == 3);
        assert!(sqrt_u128(100) == 10);
        assert!(sqrt_u128(1000000) == 1000);
    }
}
