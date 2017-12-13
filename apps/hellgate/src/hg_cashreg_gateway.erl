-module(hg_cashreg_gateway).

-include_lib("include/cashreg_events.hrl").
-include_lib("include/payment_events.hrl").
-include_lib("dmsl/include/dmsl_domain_thrift.hrl").
-include_lib("dmsl/include/dmsl_payment_processing_thrift.hrl").
-include_lib("cashreg_proto/include/cashreg_proto_main_thrift.hrl").
-include_lib("cashreg_proto/include/cashreg_proto_proxy_provider_thrift.hrl").
-include_lib("cashreg_proto/include/cashreg_proto_processing_thrift.hrl").

-export([register_receipt/3]).
-export([get_changes/2]).

-type party()             :: dmsl_domain_thrift:'Party'().
-type invoice()           :: dmsl_domain_thrift:'Invoice'().
-type payment()           :: dmsl_domain_thrift:'InvoicePayment'().
-type change()            :: dmsl_payment_processing_thrift:'InvoicePaymentReceiptChange'().
-type event_range()       :: dmsl_payment_processing_thrift:'EventRange'().
-type receipt_id()        :: cashreg_proto_main_thrift:'ReceiptID'().

-spec register_receipt(party(), invoice(), payment()) ->
    receipt_id().
register_receipt(Party, Invoice, Payment) ->
    ReceiptParams = construct_receipt_params(Party, Invoice, Payment),
    Proxy = construct_proxy(Party, Invoice),
    create_receipt(ReceiptParams, Proxy).

-spec get_changes(receipt_id(), event_range()) ->
    [change()].
get_changes(ReceiptID, EventRange) ->
    CashregEventRange = construct_event_range(EventRange),
    Events = get_receipt_events(ReceiptID, CashregEventRange),
    construct_payment_changes(Events).

construct_receipt_params(Party, Invoice, Payment) ->
    #cashreg_main_ReceiptParams{
        party = construct_party(Party, Invoice),
        operation = construct_operation(Payment),
        purchase = construct_purchase(Invoice),
        payment = construct_payment(Payment)
    }.

construct_party(Party, Invoice) ->
    Shop = hg_party:get_shop(Invoice#domain_Invoice.shop_id, Party),
    Contract = hg_party:get_contract(Shop#domain_Shop.contract_id, Party),
    RussianLegalEntity = get_russian_legal_entity(Contract),
    #cashreg_main_Party{
        registered_name = RussianLegalEntity#domain_RussianLegalEntity.registered_name,
        registered_number = RussianLegalEntity#domain_RussianLegalEntity.registered_number,
        inn = RussianLegalEntity#domain_RussianLegalEntity.inn,
        actual_address = RussianLegalEntity#domain_RussianLegalEntity.actual_address,
        tax_system = get_tax_system(Shop#domain_Shop.cash_register),
        shop = construct_shop(Shop)
    }.

get_tax_system(undefined) ->
    undefined;
get_tax_system(#domain_ShopCashRegister{tax_system = TaxSystem}) ->
    TaxSystem.

get_russian_legal_entity(
    #domain_Contract{
        contractor = {legal_entity, {russian_legal_entity, RussianLegalEntity}}
    }
) ->
    RussianLegalEntity.

construct_shop(#domain_Shop{
    details = #domain_ShopDetails{name = Name, description = Description},
    location = Location
}) ->
    #cashreg_main_Shop{
        name = Name,
        description = Description,
        location = Location
    }.

construct_operation(_) ->
    sell.

construct_purchase(#domain_Invoice{
    details = #domain_InvoiceDetails{
        cart = #domain_InvoiceCart{
            lines = Lines
        }
    }
}) ->
    #cashreg_main_Purchase{
        lines = [construct_purchase_line(Line) || Line <- Lines]
    }.

construct_purchase_line(#domain_InvoiceLine{
    product = Product,
    quantity = Quantity,
    price = Price,
    tax = Tax
}) ->
    #cashreg_main_PurchaseLine{
        product = Product,
        quantity = Quantity,
        price = construct_cash(Price),
        tax = Tax
    }.

construct_cash(#domain_Cash{
    amount = Amount,
    currency = CurrencyRef
}) ->
    Revision = hg_domain:head(),
    Currency = hg_domain:get(Revision, {currency, CurrencyRef}),
    #cashreg_main_Cash{
        amount = Amount,
        currency = construct_currency(Currency)
    }.

construct_currency(#domain_Currency{
    name = Name,
    symbolic_code = CurrencySymbolicCode,
    numeric_code = NumericCode,
    exponent = Exponent
}) ->
    #cashreg_main_Currency{
        name = Name,
        symbolic_code = CurrencySymbolicCode,
        numeric_code = NumericCode,
        exponent = Exponent
    }.

construct_payment(#domain_InvoicePayment{
    payer = Payer,
    cost = Cash
}) ->
    #cashreg_main_Payment{
        payment_method = construct_payment_method(Payer),
        cash = construct_cash(Cash)
    }.

construct_payment_method(
    {payment_resource, #domain_PaymentResourcePayer{
        resource = #domain_DisposablePaymentResource{
            payment_tool = {bank_card, _}
        }
    }}
) ->
    bank_card;
construct_payment_method(
    {customer, #domain_CustomerPayer{
        payment_tool = {bank_card, _}
    }}
) ->
    bank_card.

construct_event_range(#payproc_EventRange{
    'after' = LastEventID,
    limit = Limit
}) ->
    #cashreg_proc_EventRange{
        'after' = LastEventID,
        limit = Limit
    }.

construct_payment_changes(ReceiptEvents) ->
    lists:flatmap(
        fun(#cashreg_proc_ReceiptEvent{source = ReceiptID, payload = Changes}) ->
            lists:foldl(
                fun(Change, Acc) ->
                Acc ++ construct_payment_change(ReceiptID, Change)
            end,
            [],
            Changes
            )
        end,
        ReceiptEvents
    ).

construct_payment_change(ReceiptID, ?cashreg_receipt_created(_, _)) ->
    [?receipt_ev(ReceiptID, ?receipt_created())];
construct_payment_change(ReceiptID, ?cashreg_receipt_registered(_)) ->
    [?receipt_ev(ReceiptID, ?receipt_registered())];
construct_payment_change(ReceiptID, ?cashreg_receipt_failed(
    {receipt_registration_failed, #cashreg_main_ReceiptRegistrationFailed{
        reason = #cashreg_main_ExternalFailure{code = Code, description = Description}
    }}
)) ->
    Failure = {external_failure, #domain_ExternalFailure{code = Code, description = Description}},
    [?receipt_ev(ReceiptID, ?receipt_failed(Failure))];
construct_payment_change(_, ?cashreg_receipt_session_changed(_)) ->
    [].

create_receipt(ReceiptParams, Proxy) ->
    case issue_receipt_call('CreateReceipt', [ReceiptParams, Proxy]) of
        {ok, Receipt} ->
            Receipt#cashreg_main_Receipt.id;
        Error ->
            Error
    end.

get_receipt_events(ReceiptID, EventRange) ->
    case issue_receipt_call('GetReceiptEvents', [ReceiptID, EventRange]) of
        {ok, Events} ->
            Events;
        Error ->
            Error
    end.

issue_receipt_call(Function, Args) ->
    hg_woody_wrapper:call(cashreg, Function, Args).

construct_proxy(Party, Invoice) ->
    Shop = hg_party:get_shop(Invoice#domain_Invoice.shop_id, Party),
    construct_proxy(Shop).

construct_proxy(#domain_Shop{
    cash_register = #domain_ShopCashRegister{
        ref = CashRegisterRef,
        options = CashRegOptions
    }
}) ->
    Revision = hg_domain:head(),
    CashRegister = hg_domain:get(Revision, {cash_register, CashRegisterRef}),
    Proxy = CashRegister#domain_CashRegister.proxy,
    ProxyDef = hg_domain:get(Revision, {proxy, Proxy#domain_Proxy.ref}),
    #cashreg_prxprv_Proxy{
        url = ProxyDef#domain_ProxyDefinition.url,
        options = CashRegOptions % ProxyDef#domain_ProxyDefinition.options translate to msgpack and added here
    }.