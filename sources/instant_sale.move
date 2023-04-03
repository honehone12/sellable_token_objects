module sellable_token_objects::instant_sale {
    use std::signer;
    use std::error;
    use std::string::String;
    use std::option::{Self, Option};
    use aptos_framework::coin;
    use aptos_framework::object::{Self, Object, ExtendRef};
    use aptos_token_objects::token;
    use components_common::components_common::{Self, ComponentGroup, TransferKey};
    use components_common::royalty_utils;

    const E_NOT_TOKEN: u64 = 1;
    const E_NOT_OWNER: u64 = 2;
    const E_NOT_FOR_SALE: u64 = 3;
    const E_INVALID_PRICE: u64 = 4;
    const E_ALREADY_OWNER: u64 = 5;
    const E_OWNER_CHANGED: u64 = 6;
    const E_OBJECT_REF_NOT_MATCH: u64 = 7;
    const E_EMPTY_COIN: u64 = 8;

    #[resource_group_member(group = ComponentGroup)]
    struct TransferConfig has key {
        transfer_key: Option<TransferKey>
    }

    #[resource_group_member(group = ComponentGroup)]
    struct Sale<phantom TCoin> has key {
        lister: Option<address>,
        price: u64
    }

    public fun init_for_coin_type<T: key, TCoin>(
        extend_ref: &ExtendRef,
        object: Object<T>,
        collection_name: String,
        token_name: String
    ) {
        let obj_signer = object::generate_signer_for_extending(extend_ref);
        let obj_addr = signer::address_of(&obj_signer);
        assert!(
            obj_addr == object::object_address(&object), 
            error::invalid_argument(E_OBJECT_REF_NOT_MATCH)
        );
        assert!(
            token::collection(object) == collection_name &&
            token::name(object) == token_name,
            error::invalid_argument(E_NOT_TOKEN)
        );

        if (!exists<TransferConfig>(obj_addr)) {
            move_to(
                &obj_signer,
                TransferConfig{
                    transfer_key: option::none()
                }
            );
        };

        move_to(
            &obj_signer,
            Sale<TCoin>{
                lister: option::none(),
                price: 0
            }
        );
    }

    public fun start_sale<T: key, TCoin>(
        owner: &signer, 
        transfer_key: TransferKey,
        object: Object<T>, 
        price: u64
    )
    acquires Sale, TransferConfig {
        let owner_addr = signer::address_of(owner);
        assert!(object::is_owner(object, owner_addr), error::permission_denied(E_NOT_OWNER));
        assert!(
            object::object_address(&object) == components_common::object_address(&transfer_key),
            error::invalid_argument(E_OBJECT_REF_NOT_MATCH)
        );
        assert!(
            0 < price && price < 0xffff_ffff_ffff_ffff,
            error::invalid_argument(E_INVALID_PRICE)
        );

        let obj_addr = object::object_address(&object);
        let sale = borrow_global_mut<Sale<TCoin>>(obj_addr);
        option::fill(&mut sale.lister, owner_addr); 
        sale.price = price;

        let transfer_config = borrow_global_mut<TransferConfig>(obj_addr);
        option::fill(&mut transfer_config.transfer_key, transfer_key);
    }

    public entry fun set_price<T: key, TCoin>(owner: &signer, object: Object<T>, price: u64)
    acquires Sale {
        assert!(
            object::is_owner(object, signer::address_of(owner)),
            error::permission_denied(E_NOT_OWNER)
        );
        assert!(
            0 < price && price < 0xffff_ffff_ffff_ffff,
            error::invalid_argument(E_INVALID_PRICE)
        );

        let sale = borrow_global_mut<Sale<TCoin>>(object::object_address(&object));
        assert!(option::is_some(&sale.lister), error::invalid_argument(E_NOT_FOR_SALE));
        sale.price = price;
    }

    public entry fun close<T: key, TCoin>(owner: &signer, object: Object<T>)
    acquires Sale {
        assert!(
            object::is_owner(object, signer::address_of(owner)),
            error::permission_denied(E_NOT_OWNER)
        );       

        let sale = borrow_global_mut<Sale<TCoin>>(object::object_address(&object));
        sale.lister = option::none();
        sale.price = 0;
    }

    public fun freeze_sale<T: key, TCoin>(owner: &signer, object: Object<T>): TransferKey
    acquires Sale, TransferConfig {
        close<T, TCoin>(owner, object);
        let config = borrow_global_mut<TransferConfig>(object::object_address(&object));
        option::extract(&mut config.transfer_key)
    }

    public entry fun flash_buy<T: key, TCoin>(buyer: &signer, object: Object<T>)
    acquires Sale, TransferConfig {
        let buyer_addr = signer::address_of(buyer);
        assert!(!object::is_owner(object, buyer_addr), error::permission_denied(E_ALREADY_OWNER));
        let obj_addr = object::object_address(&object);
        let sale = borrow_global_mut<Sale<TCoin>>(obj_addr);
        let owner = object::owner(object);
        assert!(option::extract(&mut sale.lister) == owner, error::internal(E_OWNER_CHANGED));
        
        let coin = coin::withdraw<TCoin>(buyer, sale.price);
        sale.price = 0;

        royalty_utils::execute_royalty<T, TCoin>(&mut coin, object);
        assert!(coin::value(&coin) > 0, error::resource_exhausted(E_EMPTY_COIN));

        let transfer_config = borrow_global<TransferConfig>(obj_addr);
        let linear_transfer = components_common::generate_linear_transfer_ref(option::borrow(&transfer_config.transfer_key));
        object::transfer_with_ref(linear_transfer, buyer_addr);
        coin::deposit(owner, coin);
    }

    #[test_only]
    use std::string::utf8;
    #[test_only]
    use aptos_token_objects::collection;
    #[test_only]
    use aptos_token_objects::royalty;
    #[test_only]
    use aptos_framework::coin::FakeMoney;
    #[test_only]
    use aptos_framework::account;

    #[test_only]
    struct FreePizzaPass has key {}
    #[test_only]
    struct AnotherCoin {}

    #[test_only]
    fun setup_test(account_1: &signer, account_2: &signer, framework: &signer)
    : (Object<FreePizzaPass>, ExtendRef, TransferKey) {
        account::create_account_for_test(signer::address_of(account_1));
        account::create_account_for_test(signer::address_of(account_2));
        account::create_account_for_test(signer::address_of(framework));
        coin::create_fake_money(framework, framework, 200);
        coin::register<FakeMoney>(account_1);
        coin::register<FakeMoney>(account_2);
        coin::transfer<FakeMoney>(framework, signer::address_of(account_1), 100);
        coin::transfer<FakeMoney>(framework, signer::address_of(account_2), 100);

        _ = collection::create_untracked_collection(
            account_1,
            utf8(b"collection1 description"),
            utf8(b"collection1"),
            option::none(),
            utf8(b"collection1 uri"),
        );
        let cctor_1 = token::create(
            account_1,
            utf8(b"collection1"),
            utf8(b"description1"),
            utf8(b"name1"),
            option::some(royalty::create(10, 100, signer::address_of(account_1))),
            utf8(b"uri1")
        );
        move_to(&object::generate_signer(&cctor_1), FreePizzaPass{});
        let obj_1 = object::object_from_constructor_ref(&cctor_1);
        let ex_1 = object::generate_extend_ref(&cctor_1);

        init_for_coin_type<FreePizzaPass, FakeMoney>(&ex_1, obj_1, utf8(b"collection1"), utf8(b"name1"));
        (obj_1, ex_1, components_common::create_transfer_key(cctor_1))
    }

    #[test(account_1 = @0x123, account_2 = @0x234, framework = @0x1)]
    fun test_for_another_coin(account_1: &signer, account_2: &signer, framework: &signer) {
        let (obj, ex, key) = setup_test(account_1, account_2, framework);
        init_for_coin_type<FreePizzaPass, AnotherCoin>(&ex, obj, utf8(b"collection1"), utf8(b"name1"));
        components_common::destroy_for_test(key);
        assert!(exists<Sale<AnotherCoin>>(object::object_address(&obj)), 0);
    }

    #[test(account_1 = @0x123, account_2 = @0x234, framework = @0x1)]
    #[expected_failure(abort_code = 65537, location = Self)]
    fun test_fail_init_wrong_collection(account_1: &signer, account_2: &signer, framework: &signer) {
        let (obj, ex, key) = setup_test(account_1, account_2, framework);
        init_for_coin_type<FreePizzaPass, AnotherCoin>(&ex, obj, utf8(b"collection-bad"), utf8(b"name1"));
        components_common::destroy_for_test(key);
        assert!(exists<Sale<AnotherCoin>>(object::object_address(&obj)), 0);
    }

    #[test(account_1 = @0x123, account_2 = @0x234, framework = @0x1)]
    #[expected_failure(abort_code = 65537, location = Self)]
    fun test_fail_init_wrong_token(account_1: &signer, account_2: &signer, framework: &signer) {
        let (obj, ex, key) = setup_test(account_1, account_2, framework);
        init_for_coin_type<FreePizzaPass, AnotherCoin>(&ex, obj, utf8(b"collection1"), utf8(b"name-bad"));
        components_common::destroy_for_test(key);
        assert!(exists<Sale<AnotherCoin>>(object::object_address(&obj)), 0);
    }

    #[test(account_1 = @0x123, account_2 = @0x234, framework = @0x1)]
    #[expected_failure(abort_code = 327682, location = Self)]
    fun test_fail_start_sale_not_owner(account_1: &signer, account_2: &signer, framework: &signer)
    acquires Sale, TransferConfig {
        let (obj, _, key) = setup_test(account_1, account_2, framework);
        components_common::disable_transfer(&mut key);
        start_sale<FreePizzaPass, FakeMoney>(account_2, key, obj, 1);
    }

    #[test(account_1 = @0x123, account_2 = @0x234, framework = @0x1)]
    #[expected_failure(abort_code = 65540, location = Self)]
    fun test_fail_start_sale_zero(account_1: &signer, account_2: &signer, framework: &signer)
    acquires Sale, TransferConfig {
        let (obj, _, key) = setup_test(account_1, account_2, framework);
        components_common::disable_transfer(&mut key);
        start_sale<FreePizzaPass, FakeMoney>(account_1, key, obj, 0);
    }

    #[test(account_1 = @0x123, account_2 = @0x234, framework = @0x1)]
    #[expected_failure(abort_code = 65540, location = Self)]
    fun test_fail_start_sale_over(account_1: &signer, account_2: &signer, framework: &signer)
    acquires Sale, TransferConfig {
        let (obj, _, key) = setup_test(account_1, account_2, framework);
        components_common::disable_transfer(&mut key);
        start_sale<FreePizzaPass, FakeMoney>(account_1, key, obj, 0xffffffff_ffffffff);
    }

    #[test(account_1 = @0x123, account_2 = @0x234, framework = @0x1)]
    fun test(account_1: &signer, account_2: &signer, framework: &signer)
    acquires Sale, TransferConfig {
        let (obj, _, key) = setup_test(account_1, account_2, framework);
        let obj_addr = object::object_address(&obj);
        components_common::disable_transfer(&mut key);
        start_sale<FreePizzaPass, FakeMoney>(account_1, key, obj, 10);
        {
            let sale = borrow_global<Sale<FakeMoney>>(obj_addr);
            assert!(sale.price == 10, 0);
            assert!(*option::borrow(&sale.lister) == @0x123, 1);
            let transfer_config = borrow_global<TransferConfig>(obj_addr);
            assert!(option::is_some(&transfer_config.transfer_key), 2);
        };

        flash_buy<FreePizzaPass, FakeMoney>(account_2, obj);
        {
            assert!(object::is_owner(obj, @0x234), 3);
            assert!(coin::balance<FakeMoney>(@0x234) == 90, 4);
            assert!(coin::balance<FakeMoney>(@0x123) == 110, 5);

            let sale = borrow_global<Sale<FakeMoney>>(obj_addr);
            assert!(sale.price == 0, 6);
            assert!(option::is_none(&sale.lister), 7);
            let transfer_config = borrow_global<TransferConfig>(obj_addr);
            assert!(option::is_some(&transfer_config.transfer_key), 8);
        };

        let ret = freeze_sale<FreePizzaPass, FakeMoney>(account_2, obj);
        components_common::destroy_for_test(ret);
    }

    #[test(account_1 = @0x123, account_2 = @0x234, framework = @0x1)]
    fun test_set_close(account_1: &signer, account_2: &signer, framework: &signer)
    acquires Sale, TransferConfig {
        let (obj, _, key) = setup_test(account_1, account_2, framework);
        let obj_addr = object::object_address(&obj);
        components_common::disable_transfer(&mut key);
        start_sale<FreePizzaPass, FakeMoney>(account_1, key, obj, 10);
        
        set_price<FreePizzaPass, FakeMoney>(account_1, obj, 20);
        {
            let sale = borrow_global<Sale<FakeMoney>>(obj_addr);
            assert!(sale.price == 20, 0);
            assert!(*option::borrow(&sale.lister) == @0x123, 1);
            let transfer_config = borrow_global<TransferConfig>(obj_addr);
            assert!(option::is_some(&transfer_config.transfer_key), 2);
        };

        close<FreePizzaPass, FakeMoney>(account_1, obj);
        {
            let sale = borrow_global<Sale<FakeMoney>>(obj_addr);
            assert!(sale.price == 0, 6);
            assert!(option::is_none(&sale.lister), 7);
            let transfer_config = borrow_global<TransferConfig>(obj_addr);
            assert!(option::is_some(&transfer_config.transfer_key), 8);    
        }
    }

    #[test(account_1 = @0x123, account_2 = @0x234, framework = @0x1)]
    #[expected_failure(abort_code = 327682, location = Self)]
    fun test_fail_set_not_owner(account_1: &signer, account_2: &signer, framework: &signer)
    acquires Sale, TransferConfig {
        let (obj, _, key) = setup_test(account_1, account_2, framework);
        components_common::disable_transfer(&mut key);
        start_sale<FreePizzaPass, FakeMoney>(account_1, key, obj, 10);
        set_price<FreePizzaPass, FakeMoney>(account_2, obj, 20);
    }

    #[test(account_1 = @0x123, account_2 = @0x234, framework = @0x1)]
    #[expected_failure(abort_code = 65539, location = Self)]
    fun test_fail_set_not_started(account_1: &signer, account_2: &signer, framework: &signer)
    acquires Sale {
        let (obj, _, key) = setup_test(account_1, account_2, framework);
        components_common::disable_transfer(&mut key);
        set_price<FreePizzaPass, FakeMoney>(account_1, obj, 20);
        components_common::destroy_for_test(key);
    }

    #[test(account_1 = @0x123, account_2 = @0x234, framework = @0x1)]
    #[expected_failure]
    fun test_fail_freeze_not_started(account_1: &signer, account_2: &signer, framework: &signer)
    acquires Sale, TransferConfig {
        let (obj, _, key) = setup_test(account_1, account_2, framework);
        components_common::disable_transfer(&mut key);
        let ret = freeze_sale<FreePizzaPass, FakeMoney>(account_1, obj);
        
        components_common::destroy_for_test(key);
        components_common::destroy_for_test(ret);
    }

    #[test(account_1 = @0x123, account_2 = @0x234, framework = @0x1)]
    #[expected_failure(abort_code = 327682, location = Self)]
    fun test_fail_close_not_owner(account_1: &signer, account_2: &signer, framework: &signer)
    acquires Sale, TransferConfig {
        let (obj, _, key) = setup_test(account_1, account_2, framework);
        components_common::disable_transfer(&mut key);
        start_sale<FreePizzaPass, FakeMoney>(account_1, key, obj, 10);
        close<FreePizzaPass, FakeMoney>(account_2, obj);
    }

    #[test(account_1 = @0x123, account_2 = @0x234, framework = @0x1)]
    #[expected_failure(abort_code = 327685, location = Self)]
    fun test_fail_buy_self(account_1: &signer, account_2: &signer, framework: &signer)
    acquires Sale, TransferConfig {
        let (obj, _, key) = setup_test(account_1, account_2, framework);
        components_common::disable_transfer(&mut key);
        start_sale<FreePizzaPass, FakeMoney>(account_1, key, obj, 10);
        flash_buy<FreePizzaPass, FakeMoney>(account_1, obj);
    }

    #[test(account_1 = @0x123, account_2 = @0x234, framework = @0x1)]
    #[expected_failure]
    fun test_fail_buy_shortage(account_1: &signer, account_2: &signer, framework: &signer)
    acquires Sale, TransferConfig {
        let (obj, _, key) = setup_test(account_1, account_2, framework);
        components_common::disable_transfer(&mut key);
        start_sale<FreePizzaPass, FakeMoney>(account_1, key, obj, 110);
        flash_buy<FreePizzaPass, FakeMoney>(account_2, obj);
    }

    #[test(account_1 = @0x123, account_2 = @0x234, framework = @0x1)]
    #[expected_failure(abort_code = 327685, location = Self)]
    fun test_fail_buy_twice(account_1: &signer, account_2: &signer, framework: &signer)
    acquires Sale, TransferConfig {
        let (obj, _, key) = setup_test(account_1, account_2, framework);
        components_common::disable_transfer(&mut key);
        start_sale<FreePizzaPass, FakeMoney>(account_1, key, obj, 10);
        flash_buy<FreePizzaPass, FakeMoney>(account_2, obj);
        flash_buy<FreePizzaPass, FakeMoney>(account_2, obj);
    }

    #[test(account_1 = @0x123, account_2 = @0x234, framework = @0x1)]
    #[expected_failure]
    fun test_fail_buy_closed(account_1: &signer, account_2: &signer, framework: &signer)
    acquires Sale, TransferConfig {
        let (obj, _, key) = setup_test(account_1, account_2, framework);
        components_common::disable_transfer(&mut key);
        start_sale<FreePizzaPass, FakeMoney>(account_1, key, obj, 10);
        close<FreePizzaPass, FakeMoney>(account_1, obj);
        flash_buy<FreePizzaPass, FakeMoney>(account_2, obj);
    }

    #[test(account_1 = @0x123, account_2 = @0x234, framework = @0x1)]
    #[expected_failure]
    fun test_fail_buy_freezed(account_1: &signer, account_2: &signer, framework: &signer)
    acquires Sale, TransferConfig {
        let (obj, _, key) = setup_test(account_1, account_2, framework);
        components_common::disable_transfer(&mut key);
        start_sale<FreePizzaPass, FakeMoney>(account_1, key, obj, 10);
        let ret = freeze_sale<FreePizzaPass, FakeMoney>(account_1, obj);
        flash_buy<FreePizzaPass, FakeMoney>(account_2, obj);
        components_common::destroy_for_test(ret);
    }

    #[test(account_1 = @0x123, account_2 = @0x234, framework = @0x1)]
    fun test_royalty(account_1: &signer, account_2: &signer, framework: &signer)
    acquires Sale, TransferConfig {
        let (obj, _, key) = setup_test(account_1, account_2, framework);
        let obj_addr = object::object_address(&obj);
        object::transfer(account_1, obj, @0x234);
        components_common::disable_transfer(&mut key);
        
        start_sale<FreePizzaPass, FakeMoney>(account_2, key, obj, 10);
        {
            let sale = borrow_global<Sale<FakeMoney>>(obj_addr);
            assert!(sale.price == 10, 0);
            assert!(*option::borrow(&sale.lister) == @0x234, 1);
            let transfer_config = borrow_global<TransferConfig>(obj_addr);
            assert!(option::is_some(&transfer_config.transfer_key), 2);
        };

        flash_buy<FreePizzaPass, FakeMoney>(account_1, obj);
        {
            assert!(object::is_owner(obj, @0x123), 3);
            assert!(coin::balance<FakeMoney>(@0x234) == 109, 4);
            assert!(coin::balance<FakeMoney>(@0x123) == 91, 5);

            let sale = borrow_global<Sale<FakeMoney>>(obj_addr);
            assert!(sale.price == 0, 6);
            assert!(option::is_none(&sale.lister), 7);
            let transfer_config = borrow_global<TransferConfig>(obj_addr);
            assert!(option::is_some(&transfer_config.transfer_key), 8);
        };

        let ret = freeze_sale<FreePizzaPass, FakeMoney>(account_1, obj);
        components_common::destroy_for_test(ret);
    }
}