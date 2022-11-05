/// # Module-level documentation sections
///
/// * [Background](#Background)
/// * [Implementation](#Implementation)
/// * [Basic public functions](#Basic-public-functions)
/// * [Traversal](#Traversal)
///
/// # Background
///
/// AMM
/// 
module sea::amm {
    use std::option;
    use std::signer::address_of;
    use std::string::{Self, String};
    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::timestamp;
    use u256::u256;
    use uq64x64::uq64x64;

    use sea::math;
    use sea::escrow;

    // Friends >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>
    friend sea::spot;

    // Constants ====================================================
    const MIN_LIQUIDITY: u64 = 500;

    const E_NO_AUTH:                       u64 = 5000;
    const E_INITIALIZED:                   u64 = 5001;
    const E_POOL_LOCKED:                   u64 = 5002;
    const E_MIN_LIQUIDITY:                 u64 = 5003;
    const E_INSUFFICIENT_LIQUIDITY_BURNED: u64 = 5004;
    const E_INSUFFICIENT_INPUT_AMOUNT:     u64 = 5005;
    const E_INSUFFICIENT_OUTPUT_AMOUNT:    u64 = 5006;
    const ERR_K_ERROR:                     u64 = 5007;
    const E_INVALID_LOAN_PARAM:            u64 = 5008;
    const E_INSUFFICIENT_AMOUNT:           u64 = 5009;
    const E_PAY_LOAN_ERROR:                u64 = 5010;
    const E_INSUFFICIENT_BASE_AMOUNT:      u64 = 5011;
    const E_INSUFFICIENT_QUOTE_AMOUNT:     u64 = 5012;
    const E_INTERNAL_ERROR:                u64 = 5013;

    // LP token
    struct LP<phantom BaseType, phantom QuoteType, phantom FeeRatio> {}

    // Pool liquidity pool
    struct Pool<phantom BaseType, phantom QuoteType, phantom FeeRatio> has key {
        base_id: u64,
        quote_id: u64,
        base_reserve: Coin<BaseType>,
        quote_reserve: Coin<QuoteType>,
        last_timestamp: u64,
        last_price_x_cumulative: u128,
        last_price_y_cumulative: u128,
        k_last: u128,
        lp_mint_cap: coin::MintCapability<LP<BaseType, QuoteType, FeeRatio>>,
        lp_burn_cap: coin::BurnCapability<LP<BaseType, QuoteType, FeeRatio>>,
        locked: bool,
        fee: u64,
    }

    // AMMConfig global AMM config
    struct AMMConfig has key {
        dao_fee: u64, // DAO will take 1/dao_fee from trade fee

    }

    // Flashloan flash loan
    struct Flashloan<phantom BaseType, phantom QuoteType> {
        x_loan: u64,
        y_loan: u64,
    }

    // initialize
    fun init_module(sea_admin: &signer) {
        // init amm config
        assert!(address_of(sea_admin) == @sea, E_NO_AUTH);
        assert!(!exists<AMMConfig>(address_of(sea_admin)), E_INITIALIZED);
        // let signer_cap = spot_account::retrieve_signer_cap(sea_admin);
        // move_to(sea_admin, SpotAccountCapability { signer_cap });
        move_to(sea_admin, AMMConfig {
            dao_fee: 10, // 1/10
        });
    }

    // create_pool should be called by spot register_pair
    public(friend) fun create_pool<B, Q, F>(
        pair_account: &signer,
        base_id: u64,
        quote_id: u64,
        fee: u64,
    ) {
        let (name, symbol) = get_lp_name_symbol<B, Q>();
        let (lp_burn_cap, lp_freeze_cap, lp_mint_cap) =
            coin::initialize<LP<B, Q, F>>(
                pair_account,
                name,
                symbol,
                6,
                true
            );
        coin::destroy_freeze_cap(lp_freeze_cap);

        let pool = Pool<B, Q, F> {
            base_id: base_id,
            quote_id: quote_id,
            base_reserve: coin::zero<B>(),
            quote_reserve: coin::zero<Q>(),
            last_timestamp: 0,
            last_price_x_cumulative: 0,
            last_price_y_cumulative: 0,
            k_last: 0,
            lp_mint_cap,
            lp_burn_cap,
            locked: false,
            fee: fee,
        };
        move_to(pair_account, pool);
        coin::register<LP<B, Q, F>>(pair_account);
    }

    public fun get_min_liquidity(): u64 {
        MIN_LIQUIDITY
    }
    
    public fun pool_exist<B, Q, F>(): bool {
        exists<Pool<B, Q, F>>(@sea_spot)
    }

    public fun mint<B, Q, F>(
        base: Coin<B>,
        quote: Coin<Q>,
    ): Coin<LP<B, Q, F>> acquires Pool {
        escrow::validate_pair<B, Q>();
        let pool = borrow_global_mut<Pool<B, Q, F>>(@sea_spot);
        assert!(pool.locked == false, E_POOL_LOCKED);

        let total_supply = option::extract(&mut coin::supply<LP<B, Q, F>>());
        let base_reserve = coin::value(&pool.base_reserve);
        let quote_reserve = coin::value(&pool.quote_reserve);
        let base_vol = coin::value(&base);
        let quote_vol = coin::value(&quote);
        let liquidity: u64;
        if (total_supply == 0) {
            liquidity = math::sqrt((base_reserve as u128) * (quote_reserve as u128));
            assert!(liquidity > MIN_LIQUIDITY, E_MIN_LIQUIDITY);
            liquidity = liquidity - MIN_LIQUIDITY;
        } else {
            let x_liq = (((base_vol as u128) * total_supply / (base_reserve as u128)) as u64);
            let y_liq = (((quote_vol as u128) * total_supply / (quote_reserve as u128)) as u64);
            liquidity = math::min_u64(x_liq, y_liq);
        };
        assert!(liquidity > 0, E_MIN_LIQUIDITY);

        coin::merge(&mut pool.base_reserve, base);
        coin::merge(&mut pool.quote_reserve, quote);

        let lp = coin::mint<LP<B, Q, F>>(liquidity, &pool.lp_mint_cap);
        update_pool(pool, base_reserve, quote_reserve);
        pool.k_last = (base_reserve as u128) * (quote_reserve as u128);

        lp
    }

    public fun burn<B, Q, F>(
        lp: Coin<LP<B, Q, F>>,
    ): (Coin<B>, Coin<Q>) acquires Pool {
        escrow::validate_pair<B, Q>();
        let pool = borrow_global_mut<Pool<B, Q, F>>(@sea_spot);
        assert!(pool.locked == false, E_POOL_LOCKED);
        let burn_vol = coin::value(&lp);

        let total_supply = option::extract(&mut coin::supply<LP<B, Q, F>>());
        let base_reserve = coin::value(&pool.base_reserve);
        let quote_reserve = coin::value(&pool.quote_reserve);

        // how much base and quote to be returned
        let base_to_return_val = (((burn_vol as u128) * (base_reserve as u128) / total_supply) as u64);
        let quote_to_return_val = (((burn_vol as u128) * (quote_reserve as u128) / total_supply) as u64);
        assert!(base_to_return_val > 0 && quote_to_return_val > 0, E_INSUFFICIENT_LIQUIDITY_BURNED);

        // Withdraw those values from reserves
        let base_coin_to_return = coin::extract(&mut pool.base_reserve, base_to_return_val);
        let quote_coin_to_return = coin::extract(&mut pool.quote_reserve, quote_to_return_val);

        update_pool<B, Q, F>(pool, base_reserve, quote_reserve);
        coin::burn(lp, &pool.lp_burn_cap);
        // todo mint LP fee to admin

        (base_coin_to_return, quote_coin_to_return)
    }

    public fun swap<B, Q, F>(
        base_in: Coin<B>,
        base_out: u64,
        quote_in: Coin<Q>,
        quote_out: u64,
    ): (Coin<B>, Coin<Q>) acquires Pool {
        escrow::validate_pair<B, Q>();
        let pool = borrow_global_mut<Pool<B, Q, F>>(@sea_spot);
        assert!(pool.locked == false, E_POOL_LOCKED);
        assert!(base_out > 0 || quote_out > 0, E_INSUFFICIENT_OUTPUT_AMOUNT);

        let base_in_vol = coin::value(&base_in);
        let quote_in_vol = coin::value(&quote_in);
        assert!(base_in_vol > 0 || quote_in_vol > 0, E_INSUFFICIENT_INPUT_AMOUNT);

        let base_reserve = coin::value(&pool.base_reserve);
        let quote_reserve = coin::value(&pool.quote_reserve);

        // Deposit new coins to liquidity pool.
        coin::merge(&mut pool.base_reserve, base_in);
        coin::merge(&mut pool.quote_reserve, quote_in);

        let base_swaped = coin::extract(&mut pool.base_reserve, base_out);
        let quote_swaped = coin::extract(&mut pool.quote_reserve, quote_out);

        let base_balance = coin::value(&mut pool.base_reserve);
        let quote_balance = coin::value(&mut pool.quote_reserve);

        assert_k_increase(base_balance, quote_balance, base_in_vol, quote_in_vol, base_reserve, quote_reserve, pool.fee);

        update_pool(pool, base_reserve, quote_reserve);

        (base_swaped, quote_swaped)
    }

    /// Calculate optimal amounts of coins to add
    public fun calc_optimal_coin_values<B, Q, F>(
        amount_base_desired: u64,
        amount_quote_desired: u64,
        amount_base_min: u64,
        amount_quote_min: u64
    ): (u64, u64) acquires Pool {
        let pool = borrow_global<Pool<B, Q, F>>(@sea_spot);
        let (reserve_base, reserve_quote) = (coin::value(&pool.base_reserve), coin::value(&pool.quote_reserve));
        if (reserve_base == 0 && reserve_quote == 0) {
            (amount_base_desired, amount_quote_desired)
        } else {
            let amount_quote_optimal = quote(amount_base_desired, reserve_base, reserve_quote);
            if (amount_quote_optimal <= amount_quote_desired) {
                assert!(amount_quote_optimal >= amount_quote_min, E_INSUFFICIENT_QUOTE_AMOUNT);
                (amount_base_desired, amount_quote_optimal)
            } else {
                let amount_base_optimal = quote(amount_quote_desired, reserve_quote, reserve_base);
                assert!(amount_base_optimal <= amount_base_desired, E_INTERNAL_ERROR);
                assert!(amount_base_optimal >= amount_base_min, E_INSUFFICIENT_BASE_AMOUNT);
                (amount_base_optimal, amount_quote_desired)
            }
        }
    }

    fun quote(
        amount_base: u64,
        reserve_base: u64,
        reserve_quote: u64
    ): u64 {
        assert!(amount_base > 0, E_INSUFFICIENT_AMOUNT);
        assert!(reserve_base > 0 && reserve_quote > 0, E_INSUFFICIENT_AMOUNT);
        ((amount_base as u128) * (reserve_quote as u128) / (reserve_base as u128) as u64)
    }

    // k should not decrease
    fun assert_k_increase(
        base_balance: u64,
        quote_balance: u64,
        base_in: u64,
        quote_in: u64,
        base_reserve: u64,
        quote_reserve: u64,
        fee: u64,
    ) {
        let base_balance_adjusted = (base_balance as u128) * 10000 - (base_in as u128) * (fee as u128);
        let quote_balance_adjusted = (quote_balance as u128) * 10000 - (quote_in as u128) * (fee as u128);
        let balance_k_old_not_scaled = (base_reserve as u128) * (quote_reserve as u128);
        let scale = 100000000;
        // should be: new_reserve_x * new_reserve_y > old_reserve_x * old_eserve_y
        // gas saving
        if (
            math::is_overflow_mul(base_balance_adjusted, quote_balance_adjusted)
            || math::is_overflow_mul(balance_k_old_not_scaled, scale)
        ) {
            let balance_xy_adjusted = u256::mul(u256::from_u128(base_balance_adjusted), u256::from_u128(quote_balance_adjusted));
            let balance_xy_old = u256::mul(u256::from_u128(balance_k_old_not_scaled), u256::from_u128(scale));
            assert!(u256::compare(&balance_xy_adjusted, &balance_xy_old) == 2, ERR_K_ERROR);
        } else {
            assert!(base_balance_adjusted * quote_balance_adjusted >= balance_k_old_not_scaled * scale, ERR_K_ERROR)
        };
    }
    
    // Get flash swap coins. User can loan any coins, and repay in the same tx.
    // In most cases, user may loan one coin, and repay the same or the other coin.
    // require X < Y.
    // * `loan_coin_x` - expected amount of X coins to loan.
    // * `loan_coin_y` - expected amount of Y coins to loan.
    // Returns both loaned X and Y coins: `(Coin<XBaseType>, Coin<QuoteType>, Flashloan<BaseType, QuoteType)`.
    public fun flash_swap<B, Q, F>(
        loan_coin_x: u64,
        loan_coin_y: u64
    ): (Coin<B>, Coin<Q>, Flashloan<B, Q>) acquires Pool {
        // assert check
        escrow::validate_pair<B, Q>();
        assert!(loan_coin_x > 0 || loan_coin_y > 0, E_INVALID_LOAN_PARAM);

        let pool = borrow_global_mut<Pool<B, Q, F>>(@sea_spot);
        assert!(pool.locked == false, E_POOL_LOCKED);
        assert!(coin::value(&pool.base_reserve) >= loan_coin_x &&
            coin::value(&pool.quote_reserve) >= loan_coin_y, E_INSUFFICIENT_AMOUNT);
        pool.locked = true;

        let x_loan = coin::extract(&mut pool.base_reserve, loan_coin_x);
        let y_loan = coin::extract(&mut pool.quote_reserve, loan_coin_y);

        // Return loaned amount.
        (x_loan, y_loan, Flashloan<B, Q> {x_loan: loan_coin_x, y_loan: loan_coin_y})
    }

    public fun pay_flash_swap<B, Q, F>(
        base_in: Coin<B>,
        quote_in: Coin<Q>,
        flash_loan: Flashloan<B, Q>
    ) acquires Pool {
        // assert check
        escrow::validate_pair<B, Q>();

        let Flashloan { x_loan, y_loan } = flash_loan;
        let amount_base_in = coin::value(&base_in);
        let amount_quote_in = coin::value(&quote_in);

        assert!(amount_base_in > 0 || amount_quote_in > 0, E_PAY_LOAN_ERROR);

        let pool = borrow_global_mut<Pool<B, Q, F>>(@sea_spot);
        let base_reserve = coin::value(&pool.base_reserve);
        let quote_reserve = coin::value(&pool.quote_reserve);

        // reserve size before loan out
        base_reserve = base_reserve + x_loan;
        quote_reserve = quote_reserve + y_loan;

        coin::merge(&mut pool.base_reserve, base_in);
        coin::merge(&mut pool.quote_reserve, quote_in);

        let base_balance = coin::value(&pool.base_reserve);
        let quote_balance = coin::value(&pool.quote_reserve);
        assert_k_increase(base_balance, quote_balance, amount_base_in, amount_quote_in, base_reserve, quote_reserve, pool.fee);
        // update internal
        update_pool(pool, base_reserve, quote_reserve);

        pool.locked = false;
    }

    // Private functions ====================================================
    fun get_lp_name_symbol<BaseType, QuoteType>(): (String, String) {
        let name = string::utf8(b"");
        string::append_utf8(&mut name, b"LP-");
        string::append(&mut name, coin::symbol<BaseType>());
        string::append_utf8(&mut name, b"-");
        string::append(&mut name, coin::symbol<QuoteType>());

        let symbol = string::utf8(b"");
        string::append(&mut symbol, coin_symbol_prefix<BaseType>());
        string::append_utf8(&mut symbol, b"-");
        string::append(&mut symbol, coin_symbol_prefix<QuoteType>());

        (name, symbol)
    }

    fun coin_symbol_prefix<CoinType>(): String {
        let symbol = coin::symbol<CoinType>();
        let prefix_length = math::min_u64(string::length(&symbol), 4);
        string::sub_string(&symbol, 0, prefix_length)
    }

    fun update_pool<B, Q, F>(
        pool: &mut Pool<B, Q, F>,
        base_reserve: u64,
        quote_reserve: u64,
    ) {
        let last_ts = pool.last_timestamp;
        let now_ts = timestamp::now_seconds();

        let time_elapsed = ((now_ts - last_ts) as u128);

        if (time_elapsed > 0 && base_reserve != 0 && quote_reserve != 0) {
            let last_price_x_cumulative = uq64x64::to_u128(uq64x64::fraction(quote_reserve, base_reserve)) * time_elapsed;
            let last_price_y_cumulative = uq64x64::to_u128(uq64x64::fraction(base_reserve, quote_reserve)) * time_elapsed;

            pool.last_price_x_cumulative = pool.last_price_x_cumulative + last_price_x_cumulative;
            pool.last_price_y_cumulative = pool.last_price_y_cumulative + last_price_y_cumulative;
        };

        pool.last_timestamp = now_ts;
    }

    fun mint_fee<B, Q, F>(
        pool: &mut Pool<B, Q, F>,
        dao_fee: u64,
    ) {
        let k_last = pool.k_last;
        let base_reserve = coin::value(&pool.base_reserve);
        let quote_reserve = coin::value(&pool.quote_reserve);

        if (k_last != 0) {
            let root_k = math::sqrt((base_reserve as u128) * (quote_reserve as u128));
            let root_k_last = math::sqrt(k_last);
            let total_supply = option::extract(&mut coin::supply<LP<B, Q, F>>());
            if (root_k > root_k_last) {
                let delta_k = ((root_k - root_k_last) as u128);
                let liquidity;
                if (math::is_overflow_mul(total_supply, delta_k)) {
                    let numerator = u256::mul(u256::from_u128(total_supply), u256::from_u128(delta_k));
                    let denominator = u256::from_u128((root_k as u128) * (dao_fee as u128) + (root_k_last as u128));
                    liquidity = u256::as_u64(u256::div(numerator, denominator));
                } else {
                    let numerator = total_supply * delta_k;
                    let denominator = (root_k as u128) * (dao_fee as u128) + (root_k_last as u128);
                    liquidity = ((numerator / denominator) as u64);
                };
                if (liquidity > 0) {
                    let coins = coin::mint<LP<B, Q, F>>(liquidity, &pool.lp_mint_cap);
                    coin::deposit(@sea_spot, coins);
                }
            }
        };
        pool.k_last = (base_reserve as u128) * (quote_reserve as u128);
    }
}