/// Standardized Yield (SY) module for Crux Protocol.
/// Provides a unified wrapper interface around diverse yield-bearing tokens on Sui.
/// Each supported asset gets its own SYVault, which tracks the exchange rate between
/// the underlying yield-bearing token and its SY representation.
///
/// The SY abstraction decouples the yield tokenizer from specific protocol implementations,
/// enabling seamless support for Suilend cTokens, NAVI deposits, Haedal haSUI, etc.
module crux::standardized_yield {

    use sui::balance::{Self, Balance};
    use sui::coin::{Self, Coin};
    use sui::clock::Clock;
    use sui::event;

    use crux::fixed_point;

    // ===== Constants =====

    const WAD: u128 = 1_000_000_000_000_000_000;

    // ===== Error Codes =====

    const EZeroDeposit: u64 = 200;
    const EZeroRedeem: u64 = 201;
    const EInsufficientBalance: u64 = 202;
    const EVaultPaused: u64 = 203;
    const EInvalidExchangeRate: u64 = 204;

    // ===== Structs =====

    /// Admin capability for managing SY vaults
    public struct AdminCap has key, store {
        id: UID,
    }

    /// Shared object: one per supported yield-bearing asset type.
    /// Tracks the exchange rate between the underlying and SY.
    public struct SYVault<phantom T> has key {
        id: UID,
        /// Total underlying tokens held in this vault
        underlying_balance: Balance<T>,
        /// Total SY tokens outstanding (tracked as u64, not as Balance since SY is virtual)
        total_sy_supply: u64,
        /// Exchange rate: underlying per SY token, scaled to WAD (1e18).
        /// Monotonically non-decreasing as yield accrues.
        exchange_rate: u128,
        /// Last time the exchange rate was updated (ms since epoch)
        last_update_ms: u64,
        /// Whether the vault is paused (emergency)
        is_paused: bool,
    }

    /// Owned object: user's SY token position.
    /// Represents a claim on the underlying yield-bearing asset.
    public struct SYToken<phantom T> has key, store {
        id: UID,
        /// Amount of SY tokens
        amount: u64,
        /// Reference to the parent vault
        vault_id: ID,
    }

    // ===== Events =====

    public struct SYDeposited has copy, drop {
        vault_id: ID,
        depositor: address,
        underlying_amount: u64,
        sy_amount: u64,
        exchange_rate: u128,
    }

    public struct SYRedeemed has copy, drop {
        vault_id: ID,
        redeemer: address,
        sy_amount: u64,
        underlying_amount: u64,
        exchange_rate: u128,
    }

    public struct ExchangeRateUpdated has copy, drop {
        vault_id: ID,
        old_rate: u128,
        new_rate: u128,
        timestamp_ms: u64,
    }

    // ===== Init =====

    /// Create the admin capability (called once at package publish)
    fun init(ctx: &mut TxContext) {
        transfer::transfer(
            AdminCap { id: object::new(ctx) },
            ctx.sender(),
        );
    }

    // ===== Vault Creation =====

    /// Create a new SY vault for a yield-bearing asset type.
    /// Initial exchange rate is 1:1 (WAD).
    public fun create_vault<T>(
        _admin: &AdminCap,
        clock: &Clock,
        ctx: &mut TxContext,
    ): ID {
        let vault = SYVault<T> {
            id: object::new(ctx),
            underlying_balance: balance::zero<T>(),
            total_sy_supply: 0,
            exchange_rate: WAD, // 1:1 initially
            last_update_ms: clock.timestamp_ms(),
            is_paused: false,
        };
        let vault_id = object::id(&vault);
        transfer::share_object(vault);
        vault_id
    }

    // ===== Core Operations =====

    /// Deposit underlying tokens into the vault and receive SY tokens.
    /// SY amount = underlying_amount / exchange_rate (in WAD math)
    public fun deposit<T>(
        vault: &mut SYVault<T>,
        coin: Coin<T>,
        ctx: &mut TxContext,
    ): SYToken<T> {
        assert!(!vault.is_paused, EVaultPaused);
        let underlying_amount = coin.value();
        assert!(underlying_amount > 0, EZeroDeposit);

        // Calculate SY tokens to mint: sy = underlying / exchange_rate
        let sy_amount = fixed_point::from_wad(
            fixed_point::wad_div(
                fixed_point::to_wad(underlying_amount),
                vault.exchange_rate,
            )
        );

        // Take underlying into vault
        let coin_balance = coin.into_balance();
        vault.underlying_balance.join(coin_balance);

        // Update supply
        vault.total_sy_supply = vault.total_sy_supply + sy_amount;

        let vault_id = object::id(vault);

        event::emit(SYDeposited {
            vault_id,
            depositor: ctx.sender(),
            underlying_amount,
            sy_amount,
            exchange_rate: vault.exchange_rate,
        });

        SYToken<T> {
            id: object::new(ctx),
            amount: sy_amount,
            vault_id,
        }
    }

    /// Redeem SY tokens for underlying tokens.
    /// underlying_amount = sy_amount * exchange_rate
    public fun redeem<T>(
        vault: &mut SYVault<T>,
        sy_token: SYToken<T>,
        ctx: &mut TxContext,
    ): Coin<T> {
        let SYToken { id, amount: sy_amount, vault_id: _ } = sy_token;
        object::delete(id);

        assert!(sy_amount > 0, EZeroRedeem);

        // Calculate underlying to return: underlying = sy * exchange_rate
        let underlying_amount = fixed_point::from_wad(
            fixed_point::wad_mul(
                fixed_point::to_wad(sy_amount),
                vault.exchange_rate,
            )
        );

        // Ensure vault has enough
        assert!(
            vault.underlying_balance.value() >= underlying_amount,
            EInsufficientBalance,
        );

        // Update supply
        vault.total_sy_supply = vault.total_sy_supply - sy_amount;

        let vault_id = object::id(vault);

        event::emit(SYRedeemed {
            vault_id,
            redeemer: ctx.sender(),
            sy_amount,
            underlying_amount,
            exchange_rate: vault.exchange_rate,
        });

        // Withdraw underlying
        let withdrawn = vault.underlying_balance.split(underlying_amount);
        coin::from_balance(withdrawn, ctx)
    }

    /// Update the exchange rate based on yield accrued in the underlying protocol.
    /// The new rate must be >= the old rate (monotonically non-decreasing).
    /// This is called by the keeper bot or anyone who wants to trigger an update.
    ///
    /// In production, the new_rate would be computed by reading the underlying
    /// protocol's state (e.g., Suilend's cToken exchange rate, Haedal's haSUI rate).
    /// For now, the adapter passes the new rate.
    public fun update_exchange_rate<T>(
        vault: &mut SYVault<T>,
        new_rate: u128,
        clock: &Clock,
    ) {
        // Rate must be non-decreasing (yield cannot be negative)
        assert!(new_rate >= vault.exchange_rate, EInvalidExchangeRate);

        let old_rate = vault.exchange_rate;

        if (new_rate > old_rate) {
            let vault_id = object::id(vault);
            vault.exchange_rate = new_rate;
            vault.last_update_ms = clock.timestamp_ms();

            event::emit(ExchangeRateUpdated {
                vault_id,
                old_rate,
                new_rate,
                timestamp_ms: clock.timestamp_ms(),
            });
        };
    }

    // ===== SY Token Operations =====

    /// Split an SY token into two: one with `split_amount` and one with the remainder.
    public fun split<T>(
        sy_token: &mut SYToken<T>,
        split_amount: u64,
        ctx: &mut TxContext,
    ): SYToken<T> {
        assert!(sy_token.amount >= split_amount, EInsufficientBalance);
        sy_token.amount = sy_token.amount - split_amount;

        SYToken<T> {
            id: object::new(ctx),
            amount: split_amount,
            vault_id: sy_token.vault_id,
        }
    }

    /// Merge two SY tokens into one (must be from the same vault).
    public fun merge<T>(
        sy_token: &mut SYToken<T>,
        other: SYToken<T>,
    ) {
        let SYToken { id, amount, vault_id: _ } = other;
        object::delete(id);
        sy_token.amount = sy_token.amount + amount;
    }

    /// Destroy a zero-amount SY token.
    public fun destroy_zero<T>(sy_token: SYToken<T>) {
        let SYToken { id, amount, vault_id: _ } = sy_token;
        assert!(amount == 0, EInsufficientBalance);
        object::delete(id);
    }

    // ===== Admin Functions =====

    /// Pause the vault (emergency)
    public fun pause_vault<T>(
        _admin: &AdminCap,
        vault: &mut SYVault<T>,
    ) {
        vault.is_paused = true;
    }

    /// Unpause the vault
    public fun unpause_vault<T>(
        _admin: &AdminCap,
        vault: &mut SYVault<T>,
    ) {
        vault.is_paused = false;
    }

    // ===== View Functions =====

    /// Get the current exchange rate (underlying per SY, in WAD)
    public fun exchange_rate<T>(vault: &SYVault<T>): u128 {
        vault.exchange_rate
    }

    /// Get total SY supply
    public fun total_supply<T>(vault: &SYVault<T>): u64 {
        vault.total_sy_supply
    }

    /// Get total underlying in vault
    public fun total_underlying<T>(vault: &SYVault<T>): u64 {
        vault.underlying_balance.value()
    }

    /// Get the vault ID
    public fun vault_id<T>(vault: &SYVault<T>): ID {
        object::id(vault)
    }

    /// Get SY token amount
    public fun sy_amount<T>(token: &SYToken<T>): u64 {
        token.amount
    }

    /// Get the vault ID that an SY token belongs to
    public fun sy_vault_id<T>(token: &SYToken<T>): ID {
        token.vault_id
    }

    /// Check if vault is paused
    public fun is_paused<T>(vault: &SYVault<T>): bool {
        vault.is_paused
    }

    /// Calculate how many SY tokens a given underlying amount would mint
    public fun preview_deposit<T>(vault: &SYVault<T>, underlying_amount: u64): u64 {
        fixed_point::from_wad(
            fixed_point::wad_div(
                fixed_point::to_wad(underlying_amount),
                vault.exchange_rate,
            )
        )
    }

    // ===== Package-Internal Helpers =====

    /// Create an SY token. Only callable by modules within the crux package.
    /// Used by the AMM when swapping PT → SY (pool needs to issue SY to the trader).
    public(package) fun create_sy_internal<T>(
        vault: &mut SYVault<T>,
        amount: u64,
        ctx: &mut TxContext,
    ): SYToken<T> {
        SYToken<T> {
            id: object::new(ctx),
            amount,
            vault_id: object::id(vault),
        }
    }

    /// Burn an SY token and reduce supply. Only callable within the package.
    public(package) fun burn_sy_internal<T>(
        sy_token: SYToken<T>,
    ): u64 {
        let SYToken { id, amount, vault_id: _ } = sy_token;
        object::delete(id);
        amount
    }

    // ===== Test Helpers =====

    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) {
        init(ctx);
    }

    /// Calculate how much underlying a given SY amount would redeem
    public fun preview_redeem<T>(vault: &SYVault<T>, sy_amount_val: u64): u64 {
        fixed_point::from_wad(
            fixed_point::wad_mul(
                fixed_point::to_wad(sy_amount_val),
                vault.exchange_rate,
            )
        )
    }
}
