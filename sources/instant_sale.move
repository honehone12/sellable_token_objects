module sellable_token_objects::instant_sale {
    use std::signer;
    use std::error;
    use std::string::String;
    use std::option::{Self, Option};
    use aptos_framework::coin;
    use aptos_framework::object::{Self, Object, TransferRef, ExtendRef, ConstructorRef};
    use aptos_token_objects::token;

    const E_NOT_TOKEN: u64 = 1;
    const E_NOT_OWNER: u64 = 2;
    const E_ALREADY_FOR_SALE: u64 = 3;
    const E_NOT_FOR_SALE: u64 = 4;
    const E_INVALID_PRICE: u64 = 5;
    const E_ALREADY_OWNER: u64 = 6;
    const E_SALE_DISABLED: u64 = 7;
    const E_NOT_ENOUGH_BALANCE: u64 = 8;
    const E_OWNER_CHANGED: u64 = 9;

    #[resource_group_member(group = object::ObjectGroup)]
    struct TransferConfig has key {
        transfer_ref: Option<TransferRef>
    }

    #[resource_group_member(group = object::ObjectGroup)]
    struct Sale<phantom TCoin> has key {
        lister: Option<address>,
        price: u64
    }

    public fun init_config<T: key>(
        constructor_ref: &ConstructorRef,
        collection_name: String,
        token_name: String
    ) {
        let obj = object::object_from_constructor_ref<T>(constructor_ref);
        assert!(
            token::collection(obj) == collection_name &&
            token::name(obj) == token_name,
            error::invalid_argument(E_NOT_TOKEN)
        );

        let obj_signer = object::generate_signer(constructor_ref);
        let transfer = object::generate_transfer_ref(constructor_ref);
        move_to(
            &obj_signer,
            TransferConfig{
                transfer_ref: option::some(transfer)
            }
        );
    }

    public fun init_for_coin_type<TCoin>(extend_ref: &ExtendRef) {
        let obj_signer = object::generate_signer_for_extending(extend_ref);
        move_to(
            &obj_signer,
            Sale<TCoin>{
                lister: option::none(),
                price: 0
            }
        );
    }

    public fun freeze_sale<T: key, TCoin>(owner: &signer, object: Object<T>)
    acquires Sale, TransferConfig {
        close<T, TCoin>(owner, object);
        let config = borrow_global_mut<TransferConfig>(object::object_address(&object));
        _ = option::extract(&mut config.transfer_ref);
    }

    public fun start_sale<T: key, TCoin>(owner: &signer, object: Object<T>, price: u64)
    acquires Sale {
        let owner_addr = signer::address_of(owner);
        assert!(object::is_owner(object, owner_addr), error::permission_denied(E_NOT_OWNER));
        assert!(
            0 < price && price < 0xffff_ffff_ffff_ffff,
            error::invalid_argument(E_INVALID_PRICE)
        );

        let sale = borrow_global_mut<Sale<TCoin>>(object::object_address(&object));
        assert!(option::is_none(&sale.lister), error::invalid_argument(E_ALREADY_FOR_SALE));
        sale.lister = option::some(owner_addr); 
        sale.price = price;
    }

    public fun set_price<T: key, TCoin>(owner: &signer, object: Object<T>, price: u64)
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

    public fun close<T: key, TCoin>(owner: &signer, object: Object<T>)
    acquires Sale {
        assert!(
            object::is_owner(object, signer::address_of(owner)),
            error::permission_denied(E_NOT_OWNER)
        );       

        let sale = borrow_global_mut<Sale<TCoin>>(object::object_address(&object));
        sale.lister = option::none();
        sale.price = 0;
    }

    public fun flash_buy<T: key, TCoin>(buyer: &signer, object: Object<T>)
    acquires Sale, TransferConfig {
        let buyer_addr = signer::address_of(buyer);
        assert!(!object::is_owner(object, buyer_addr), error::permission_denied(E_ALREADY_OWNER));
        let obj_addr = object::object_address(&object);
        let transfer_config = borrow_global<TransferConfig>(obj_addr);
        assert!(
            option::is_some(&transfer_config.transfer_ref), 
            error::unavailable(E_SALE_DISABLED)
        );

        let sale = borrow_global_mut<Sale<TCoin>>(obj_addr);
        let owner = object::owner(object);
        assert!(option::is_some(&sale.lister), error::invalid_argument(E_NOT_FOR_SALE));
        assert!(option::extract(&mut sale.lister) == owner, error::internal(E_OWNER_CHANGED));
        assert!(
            coin::balance<TCoin>(buyer_addr) >= sale.price, 
            error::invalid_argument(E_NOT_ENOUGH_BALANCE)
        );

        let coin = coin::withdraw<TCoin>(buyer, sale.price);
        sale.price = 0;
        let linear_transfer = object::generate_linear_transfer_ref(option::borrow(&transfer_config.transfer_ref));
        object::transfer_with_ref(linear_transfer, buyer_addr);
        coin::deposit(owner, coin);
    }
}