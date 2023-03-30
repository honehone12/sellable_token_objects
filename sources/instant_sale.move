module sellable_token_objects::instant_sale {
    use std::signer;
    use std::error;
    use std::string::String;
    use std::option::{Self, Option};
    use aptos_framework::coin;
    use aptos_framework::object::{Self, Object, ExtendRef};
    use aptos_token_objects::token;
    use components_common::components_common::{Self, ComponentGroup, TransferKey};

    const E_NOT_TOKEN: u64 = 1;
    const E_NOT_OWNER: u64 = 2;
    const E_NOT_FOR_SALE: u64 = 3;
    const E_INVALID_PRICE: u64 = 4;
    const E_ALREADY_OWNER: u64 = 5;
    const E_OWNER_CHANGED: u64 = 6;
    const E_OBJECT_REF_NOT_MATCH: u64 = 7;

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

    public fun freeze_sale<T: key, TCoin>(owner: &signer, object: Object<T>): TransferKey
    acquires Sale, TransferConfig {
        close<T, TCoin>(owner, object);
        let config = borrow_global_mut<TransferConfig>(object::object_address(&object));
        option::extract(&mut config.transfer_key)
    }

    public fun flash_buy<T: key, TCoin>(buyer: &signer, object: Object<T>)
    acquires Sale, TransferConfig {
        let buyer_addr = signer::address_of(buyer);
        assert!(!object::is_owner(object, buyer_addr), error::permission_denied(E_ALREADY_OWNER));
        let obj_addr = object::object_address(&object);
        let sale = borrow_global_mut<Sale<TCoin>>(obj_addr);
        let owner = object::owner(object);
        assert!(option::extract(&mut sale.lister) == owner, error::internal(E_OWNER_CHANGED));
        
        let coin = coin::withdraw<TCoin>(buyer, sale.price);
        sale.price = 0;

        let transfer_config = borrow_global<TransferConfig>(obj_addr);
        let linear_transfer = object::generate_linear_transfer_ref(
            components_common::transfer_ref(option::borrow(&transfer_config.transfer_key))
        );
        object::transfer_with_ref(linear_transfer, buyer_addr);
        coin::deposit(owner, coin);
    }
}