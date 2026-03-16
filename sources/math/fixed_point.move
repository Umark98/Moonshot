/// Fixed-point arithmetic library for Crux Protocol.
/// Uses 64-bit values with 18 decimal places (WAD = 1e18) for high-precision DeFi math.
/// Also provides 128-bit operations for intermediate calculations to prevent overflow.
module crux::fixed_point {

    // ===== Constants =====

    /// 1.0 in WAD representation (18 decimals)
    const WAD: u128 = 1_000_000_000_000_000_000;

    /// Half WAD for rounding
    const HALF_WAD: u128 = 500_000_000_000_000_000;

    /// Maximum u64 value
    const MAX_U64: u128 = 18_446_744_073_709_551_615;

    // ===== Error Codes =====

    const EOverflow: u64 = 0;
    const EDivisionByZero: u64 = 1;
    const EExponentTooLarge: u64 = 2;

    // ===== WAD Arithmetic (u128, 18 decimals) =====

    /// Returns the WAD constant (1e18)
    public fun wad(): u128 { WAD }

    /// Maximum u128 value for overflow checks
    const MAX_U128: u256 = 340_282_366_920_938_463_463_374_607_431_768_211_455;

    /// Multiply two WAD values: (a * b) / WAD, rounded down.
    /// Uses u256 intermediate to prevent overflow.
    /// SECURITY: Asserts result fits in u128.
    public fun wad_mul(a: u128, b: u128): u128 {
        let result = (a as u256) * (b as u256) / (WAD as u256);
        assert!(result <= MAX_U128, EOverflow);
        (result as u128)
    }

    /// Multiply two WAD values: (a * b + HALF_WAD) / WAD, rounded to nearest.
    /// Uses u256 intermediate to prevent overflow.
    /// SECURITY: Asserts result fits in u128.
    public fun wad_mul_round(a: u128, b: u128): u128 {
        let result = ((a as u256) * (b as u256) + (HALF_WAD as u256)) / (WAD as u256);
        assert!(result <= MAX_U128, EOverflow);
        (result as u128)
    }

    /// Divide two WAD values: (a * WAD) / b, rounded down.
    /// Uses u256 intermediate to prevent overflow.
    /// SECURITY: Asserts result fits in u128.
    public fun wad_div(a: u128, b: u128): u128 {
        assert!(b > 0, EDivisionByZero);
        let result = (a as u256) * (WAD as u256) / (b as u256);
        assert!(result <= MAX_U128, EOverflow);
        (result as u128)
    }

    /// Divide two WAD values: (a * WAD + b/2) / b, rounded to nearest.
    /// Uses u256 intermediate to prevent overflow.
    /// SECURITY: Asserts result fits in u128.
    public fun wad_div_round(a: u128, b: u128): u128 {
        assert!(b > 0, EDivisionByZero);
        let result = ((a as u256) * (WAD as u256) + ((b / 2) as u256)) / (b as u256);
        assert!(result <= MAX_U128, EOverflow);
        (result as u128)
    }

    // ===== Conversion =====

    /// Convert a u64 amount to WAD representation
    public fun to_wad(amount: u64): u128 {
        (amount as u128) * WAD
    }

    /// Convert WAD back to u64, truncating decimals
    public fun from_wad(wad_amount: u128): u64 {
        let result = wad_amount / WAD;
        assert!(result <= MAX_U64, EOverflow);
        (result as u64)
    }

    /// Convert WAD back to u64, rounding to nearest
    public fun from_wad_round(wad_amount: u128): u64 {
        let result = (wad_amount + HALF_WAD) / WAD;
        assert!(result <= MAX_U64, EOverflow);
        (result as u64)
    }

    /// Convert WAD back to u64, rounding up (ceiling division)
    public fun from_wad_round_up(wad_amount: u128): u64 {
        let result = (wad_amount + WAD - 1) / WAD;
        assert!(result <= MAX_U64, EOverflow);
        (result as u64)
    }

    // ===== Power / Exponential =====

    /// Compute base^exp where base is WAD and exp is a u64 integer.
    /// Uses binary exponentiation for O(log n) multiplications.
    public fun wad_pow(base: u128, exp: u64): u128 {
        if (exp == 0) return WAD;
        if (exp == 1) return base;

        let mut result = WAD;
        let mut b = base;
        let mut e = exp;

        while (e > 0) {
            if (e % 2 == 1) {
                result = wad_mul(result, b);
            };
            b = wad_mul(b, b);
            e = e / 2;
        };

        result
    }

    /// Approximate e^x using Taylor series where x is WAD.
    /// Good for small x values (|x| < 20 WAD). Uses 20 terms for precision.
    public fun wad_exp(x: u128): u128 {
        // For x = 0, e^0 = 1
        if (x == 0) return WAD;

        // Limit input range to prevent overflow
        assert!(x < 40 * WAD, EExponentTooLarge);

        // Taylor series: e^x = 1 + x + x^2/2! + x^3/3! + ...
        let mut term = WAD; // Current term starts at 1.0
        let mut sum = WAD;  // Running sum starts at 1.0
        let mut i: u128 = 1;

        while (i <= 20) {
            term = wad_mul(term, x) / i;
            if (term == 0) break;
            sum = sum + term;
            i = i + 1;
        };

        sum
    }

    /// Natural logarithm approximation: ln(x) where x is WAD.
    /// Uses the series ln(x) = 2 * sum( ((x-1)/(x+1))^(2k+1) / (2k+1) ) for x > 0.
    public fun wad_ln(x: u128): u128 {
        assert!(x > 0, EDivisionByZero);

        // ln(1) = 0
        if (x == WAD) return 0;

        // For x > 1, compute ln(x). For x < 1, this returns 0 (we only handle x >= 1).
        assert!(x >= WAD, EOverflow); // Only positive logarithms in this implementation

        // Reduce x to range [1, 2) by factoring out powers of 2
        // ln(x) = k * ln(2) + ln(x / 2^k)
        let ln2: u128 = 693_147_180_559_945_309; // ln(2) in WAD

        let mut val = x;
        let mut k: u128 = 0;
        let two_wad = 2 * WAD;

        while (val >= two_wad) {
            val = val / 2;
            k = k + 1;
        };

        // Now val is in [WAD, 2*WAD). Compute ln(val) using series.
        // Let t = (val - WAD) / (val + WAD), then ln(val) = 2 * (t + t^3/3 + t^5/5 + ...)
        let numerator = val - WAD;
        let denominator = val + WAD;
        let t = wad_div(numerator, denominator);

        let t_squared = wad_mul(t, t);
        let mut term = t;
        let mut sum = t;
        let mut i: u128 = 3;

        while (i <= 21) {
            term = wad_mul(term, t_squared);
            sum = sum + term / i;
            if (term / i == 0) break;
            i = i + 2;
        };

        sum = sum * 2;

        // Final result: k * ln(2) + sum
        k * ln2 + sum
    }

    // ===== Safe Arithmetic =====

    /// Safe multiply that checks for overflow
    public fun safe_mul_u64(a: u64, b: u64): u64 {
        let result = (a as u128) * (b as u128);
        assert!(result <= MAX_U64, EOverflow);
        (result as u64)
    }

    /// Safe divide
    public fun safe_div_u64(a: u64, b: u64): u64 {
        assert!(b > 0, EDivisionByZero);
        a / b
    }

    /// Minimum of two u64 values
    public fun min_u64(a: u64, b: u64): u64 {
        if (a < b) a else b
    }

    /// Maximum of two u64 values
    public fun max_u64(a: u64, b: u64): u64 {
        if (a > b) a else b
    }

    /// Minimum of two u128 values
    public fun min_u128(a: u128, b: u128): u128 {
        if (a < b) a else b
    }

    // ===== Tests =====

    #[test]
    fun test_wad_mul() {
        // 2.0 * 3.0 = 6.0
        let a = 2 * WAD;
        let b = 3 * WAD;
        assert!(wad_mul(a, b) == 6 * WAD);

        // 1.5 * 2.0 = 3.0
        let c = WAD + WAD / 2; // 1.5
        let d = 2 * WAD;
        assert!(wad_mul(c, d) == 3 * WAD);
    }

    #[test]
    fun test_wad_div() {
        // 6.0 / 3.0 = 2.0
        let a = 6 * WAD;
        let b = 3 * WAD;
        assert!(wad_div(a, b) == 2 * WAD);

        // 1.0 / 2.0 = 0.5
        assert!(wad_div(WAD, 2 * WAD) == WAD / 2);
    }

    #[test]
    fun test_conversions() {
        assert!(to_wad(100) == 100 * WAD);
        assert!(from_wad(100 * WAD) == 100);
        assert!(from_wad(WAD + WAD / 2) == 1); // truncates 1.5 to 1
        assert!(from_wad_round(WAD + WAD / 2) == 2); // rounds 1.5 to 2
    }

    #[test]
    fun test_wad_pow() {
        // 2.0^10 = 1024.0
        assert!(wad_pow(2 * WAD, 10) == 1024 * WAD);
        // x^0 = 1.0
        assert!(wad_pow(5 * WAD, 0) == WAD);
        // x^1 = x
        assert!(wad_pow(7 * WAD, 1) == 7 * WAD);
    }

    #[test]
    fun test_wad_exp() {
        // e^0 = 1.0
        assert!(wad_exp(0) == WAD);
        // e^1 ≈ 2.718...  — check within 0.001 tolerance
        let e1 = wad_exp(WAD);
        let expected = 2_718_281_828_459_045_235; // e in WAD
        let diff = if (e1 > expected) { e1 - expected } else { expected - e1 };
        assert!(diff < WAD / 1000); // within 0.001
    }

    #[test]
    fun test_wad_ln() {
        // ln(1) = 0
        assert!(wad_ln(WAD) == 0);
        // ln(e) ≈ 1.0
        let e_wad = 2_718_281_828_459_045_235;
        let ln_e = wad_ln(e_wad);
        let diff = if (ln_e > WAD) { ln_e - WAD } else { WAD - ln_e };
        assert!(diff < WAD / 100); // within 0.01
    }
}
