-module(hg_cashreg_controller).

-include_lib("cashreg_proto/include/cashreg_proto_proxy_provider_thrift.hrl").
-include_lib("cashreg_proto/include/cashreg_proto_processing_thrift.hrl").

-define(NS, <<"cashreg">>).

-export([process_callback/2]).

%% Woody handler called by hg_woody_wrapper

-behaviour(hg_woody_wrapper).
-export([handle_function/3]).

%% Machine callbacks

-behaviour(hg_machine).
-export([namespace     /0]).
-export([init          /2]).
-export([process_signal/3]).
-export([process_call  /3]).

% Types
-record(st, {
    receipt_params  :: undefined | receipt_params(),
    proxy           :: undefined | proxy(),
    session         :: undefined | session()
}).
% -type st() :: #st{}.

-type session() :: #{
    status      := undefined | suspended | finished,
    result      => session_result(),
    proxy_state => proxy_state()
}.

-type receipt_params()      :: cashreg_proto_main_thrift:'ReceiptParams'().
-type receipt_id()          :: cashreg_proto_main_thrift:'ReceiptID'().
-type session_result()      :: cashreg_proto_processing_thrift:'SessionResult'().
-type proxy()               :: cashreg_proto_proxy_provider_thrift:'Proxy'().
-type proxy_state()         :: cashreg_proto_proxy_provider_thrift:'ProxyState'().
-type tag()                 :: cashreg_proto_proxy_provider_thrift:'Tag'().
-type callback()            :: cashreg_proto_proxy_provider_thrift:'Callback'().
-type callback_response()   :: _.

%% Woody handler

-spec handle_function(woody:func(), woody:args(), hg_woody_wrapper:handler_opts()) ->
    term() | no_return().

handle_function(Func, Args, Opts) ->
    scoper:scope(cashreg,
        fun() -> handle_function_(Func, Args, Opts) end
    ).
handle_function_('CreateReceipt', [ReceiptInfo, ProxyOptions], _Opts) ->
    ReceiptID = hg_utils:unique_id(),
    ok = set_meta(ReceiptID),
    ok = start(ReceiptID, [ReceiptInfo, ProxyOptions]),
    construct_receipt(ReceiptID, ReceiptInfo);
handle_function_('GetReceiptEvents', [ReceiptID, Range], _Opts) ->
    ok = set_meta(ReceiptID),
    get_public_history(ReceiptID, Range).

%%

set_meta(ID) ->
    scoper:add_meta(#{id => ID}).

start(ID, Args) ->
    map_start_error(hg_machine:start(?NS, ID, Args)).

map_start_error({ok, _}) ->
    ok;
map_start_error({error, Reason}) ->
    error(Reason).

get_public_history(ReceiptID, #cashreg_proc_EventRange{'after' = AfterID, limit = Limit}) ->
    [publish_receipt_event(ReceiptID, Ev) || Ev <- get_history(ReceiptID, AfterID, Limit)].

publish_receipt_event(ReceiptID, {ID, Dt, Payload}) ->
    #cashreg_proc_ReceiptEvent{
        id = ID,
        created_at = Dt,
        source = ReceiptID,
        payload = Payload
    }.

get_history(Ref, AfterID, Limit) ->
    History = hg_machine:get_history(?NS, Ref, AfterID, Limit),
    unmarshal(map_history_error(History)).

map_history_error({ok, Result}) ->
    Result;
map_history_error({error, notfound}) ->
    throw({error, notfound}).

-include("cashreg_events.hrl").

%% hg_machine callbacks

-spec namespace() ->
    hg_machine:ns().
namespace() ->
    ?NS.

-spec init(receipt_id(), [receipt_params() | proxy()]) ->
    hg_machine:result().
init(_ReceiptID, [ReceiptParams, Proxy]) ->
    Changes = [?cashreg_receipt_created(ReceiptParams, Proxy)],
    Action = hg_machine_action:instant(),
    Result = #{
        changes => Changes,
        action  => Action
    },
    handle_result(Result).

-spec process_signal(hg_machine:signal(), hg_machine:history(), hg_machine:auxst()) ->
    hg_machine:result().
process_signal(Signal, History, _AuxSt) ->
    handle_result(handle_signal(Signal, collapse_history(unmarshal(History)))).

handle_signal(timeout, St) ->
    process_timeout(St).

process_timeout(#st{session = #{status := Status}} = St) ->
    Action = hg_machine_action:new(),
    case Status of
        undefined ->
            process(Action, St);
        suspended ->
            process_callback_timeout(Action, St)
    end.

process(
    Action,
    #st{
        receipt_params = ReceiptParams,
        proxy = Proxy,
        session = Session
    } = St
) ->
    ProxyState = maps:get(proxy_state, Session, undefined),
    ReceiptProxyResult = register_receipt(ReceiptParams, Proxy, ProxyState),
    Result = handle_proxy_result(ReceiptProxyResult, Action),
    finish_processing(Result, St).

register_receipt(ReceiptParams, Proxy, ProxyState) ->
    ReceiptContext = construct_receipt_context(ReceiptParams, Proxy),
    Session = construct_session(ProxyState),
    {ok, ReceiptProxyResult} = hg_cashreg_provider:register_receipt(ReceiptContext, Session, Proxy),
    ReceiptProxyResult.

process_callback_timeout(Action, St) ->
    Result = handle_proxy_callback_timeout(Action),
    finish_processing(Result, St).

handle_proxy_callback_timeout(Action) ->
    Changes = [
        ?cashreg_receipt_session_finished(?cashreg_receipt_session_failed({
            receipt_registration_failed, #cashreg_main_ReceiptRegistrationFailed{
                reason = #cashreg_main_ExternalFailure{code = <<"0">>}
            }
        }))
    ],
    make_proxy_result(Changes, Action).

make_proxy_result(Changes, Action) ->
    make_proxy_result(Changes, Action, undefined).

make_proxy_result(Changes, Action, Receipt) ->
    {wrap_session_events(Changes), Action, Receipt}.

wrap_session_events(SessionEvents) ->
    [?cashreg_receipt_session_changed(Ev) || Ev <- SessionEvents].

-spec process_call({callback, _}, hg_machine:history(), hg_machine:auxst()) ->
    {hg_machine:response(), hg_machine:result()}.
process_call(Call, History, _AuxSt) ->
    St = collapse_history(unmarshal(History)),
    try handle_result(handle_call(Call, St)) catch
        throw:Exception ->
            {{exception, Exception}, #{}}
    end.

handle_call({callback, Callback}, St) ->
    dispatch_callback(Callback, St).

dispatch_callback(
    {provider, Callback},
    #st{
        receipt_params = ReceiptParams,
        proxy = Proxy,
        session = #{status := suspended, proxy_state := ProxyState}
    } = St
) ->
    Action = hg_machine_action:new(),
    ReceiptContext = construct_receipt_context(ReceiptParams, Proxy),
    {ok, CallbackResult} = hg_cashreg_provider:handle_receipt_callback(
        Callback,
        ReceiptContext,
        construct_session(ProxyState),
        Proxy
    ),
    {Response, Result} = handle_callback_result(CallbackResult, Action),
    maps:merge(#{response => Response}, finish_processing(Result, St));
dispatch_callback(_Callback, _St) ->
    throw(invalid_callback).

handle_result(Params) ->
    Result = handle_result_changes(Params, handle_result_action(Params, #{})),
    case maps:find(response, Params) of
        {ok, Response} ->
            {{ok, Response}, Result};
        error ->
            Result
    end.

handle_result_changes(#{changes := Changes = [_ | _]}, Acc) ->
    Acc#{events => [marshal(Changes)]};
handle_result_changes(#{}, Acc) ->
    Acc.

handle_result_action(#{action := Action}, Acc) ->
    Acc#{action => Action}.
% handle_result_action(#{}, Acc) ->
%     Acc.

collapse_history(History) ->
    lists:foldl(
        fun ({_ID, _, Events}, St0) ->
            lists:foldl(fun apply_change/2, St0, Events)
        end,
        #st{},
        History
    ).

apply_changes(Changes, St) ->
    lists:foldl(fun apply_change/2, St, Changes).

apply_change(Event, undefined) ->
    apply_change(Event, #st{});

apply_change(?cashreg_receipt_created(ReceiptParams, Proxy), St) ->
    St#st{
        receipt_params = ReceiptParams,
        proxy = Proxy,
        session = #{status => undefined}
    };
apply_change(?cashreg_receipt_registered(_Receipt), St) ->
    St;
apply_change(?cashreg_receipt_failed(_Failure), St) ->
    St;

apply_change(?cashreg_receipt_session_changed(Event), #st{session = Session0} = St) ->
    Session1 = merge_session_change(Event, Session0),
    St#st{session = Session1}.

merge_session_change(?cashreg_receipt_session_started(), _) ->
    #{status => undefined};
merge_session_change(?cashreg_receipt_session_finished(Result), Session) ->
    Session#{status := finished, result => Result};
merge_session_change(?cashreg_receipt_session_suspended(_Tag), Session) ->
    Session#{status := suspended};
merge_session_change(?cashreg_receipt_proxy_st_changed(ProxyState), Session) ->
    Session#{proxy_state => ProxyState}.

-spec process_callback(tag(), {provider, callback()}) ->
    {ok, callback_response()} | {error, invalid_callback | notfound | failed} | no_return().

process_callback(Tag, Callback) ->
    case hg_machine:call(?NS, {tag, Tag}, {callback, Callback}) of
        {ok, {ok, _} = Ok} ->
            Ok;
        {ok, {exception, invalid_callback}} ->
            {error, invalid_callback};
        {error, _} = Error ->
            Error
    end.

update_proxy_state(undefined) ->
    [];
update_proxy_state(ProxyState) ->
    [?cashreg_receipt_proxy_st_changed(ProxyState)].

handle_proxy_intent(#'cashreg_prxprv_FinishIntent'{status = {success, _}}, Action) ->
    Events = [?cashreg_receipt_session_finished(?cashreg_receipt_session_succeeded())],
    {Events, Action};
handle_proxy_intent(
    #'cashreg_prxprv_FinishIntent'{status = {failure, #cashreg_prxprv_Failure{error = Error}}},
    Action
) ->
    Events = [?cashreg_receipt_session_finished(?cashreg_receipt_session_failed(Error))],
    {Events, Action};
handle_proxy_intent(#'cashreg_prxprv_SleepIntent'{timer = Timer}, Action0) ->
    Action = hg_machine_action:set_timer(Timer, Action0),
    Events = [],
    {Events, Action};
handle_proxy_intent(#'cashreg_prxprv_SuspendIntent'{tag = Tag, timeout = Timer}, Action0) ->
    Action = hg_machine_action:set_timer(Timer, hg_machine_action:set_tag(Tag, Action0)),
    Events = [?cashreg_receipt_session_suspended(Tag)],
    {Events, Action}.

handle_callback_result(
    #cashreg_prxprv_ReceiptCallbackResult{result = ProxyResult, response = Response},
    Action
) ->
    {Response, handle_proxy_callback_result(ProxyResult, hg_machine_action:unset_timer(Action))}.

handle_proxy_result(
    #cashreg_prxprv_ReceiptProxyResult{
        intent = {_Type, Intent},
        next_state = ProxyState
    },
    Action0
) ->
    Changes1 = update_proxy_state(ProxyState),
    {Changes2, Action} = handle_proxy_intent(Intent, Action0),
    handle_intent(Intent, Changes1 ++ Changes2, Action).

handle_proxy_callback_result(
    #cashreg_prxprv_ReceiptCallbackProxyResult{
        intent = {_Type, Intent},
        next_state = ProxyState
    },
    Action0
) ->
    Changes1 = update_proxy_state(ProxyState),
    {Changes2, Action} = handle_proxy_intent(Intent, hg_machine_action:unset_timer(Action0)),
    handle_intent(Intent, Changes1 ++ Changes2, Action).

handle_intent(Intent, Changes, Action) ->
    case Intent of
        #cashreg_prxprv_FinishIntent{
            status = {'success', #cashreg_prxprv_Success{receipt_reg_entry = ReceiptRegEntry}}
        } ->
            make_proxy_result(Changes, Action, ReceiptRegEntry);
        _ ->
            make_proxy_result(Changes, Action)
    end.

finish_processing({Changes, Action, Receipt}, St) ->
    #st{session = Session} = apply_changes(Changes, St),
    case Session of
        #{status := finished, result := ?cashreg_receipt_session_succeeded()} ->
            #{
                changes => Changes ++ [?cashreg_receipt_registered(Receipt)],
                action  => Action
            };
        #{status := finished, result := ?cashreg_receipt_session_failed(Failure)} ->
            #{
                changes => Changes ++ [?cashreg_receipt_failed(Failure)],
                action  => Action
            };
        #{} ->
            #{
                changes => Changes,
                action  => Action
            }
    end.

construct_receipt(
    ReceiptID,
    #cashreg_main_ReceiptParams{
        party = Party,
        operation = Opeartion,
        purchase = Purchase,
        payment = Payment,
        metadata = Metadata
    }
) ->
    #cashreg_main_Receipt{
        id = ReceiptID,
        status = {created, #cashreg_main_ReceiptCreated{}},
        party = Party,
        operation = Opeartion,
        purchase = Purchase,
        payment = Payment,
        metadata = Metadata
    }.


construct_receipt_context(ReceiptParams, Proxy) ->
    #cashreg_prxprv_ReceiptContext{
        receipt_params = ReceiptParams,
        options = Proxy#cashreg_prxprv_Proxy.options
    }.

construct_session(State) ->
    #cashreg_prxprv_Session{
        state = State
    }.

%% Marshalling

marshal(Changes) when is_list(Changes) ->
    [marshal(change, Change) || Change <- Changes].

%% Changes

marshal(change, ?cashreg_receipt_created(ReceiptParams, Proxy)) ->
    [1, #{
        <<"change">>            => <<"created">>,
        <<"receipt_params">>    => marshal(receipt_params, ReceiptParams),
        <<"proxy">>             => marshal(proxy, Proxy)
    }];
marshal(change, ?cashreg_receipt_registered(ReceiptRegEntry)) ->
    [1, #{
        <<"change">>                => <<"registered">>,
        <<"receipt_reg_entry">>     => marshal(receipt_reg_entry, ReceiptRegEntry)
    }];
marshal(change, ?cashreg_receipt_failed(Failure)) ->
    [1, #{
        <<"change">>    => <<"failed">>,
        <<"failure">>   => marshal(failure, Failure)
    }];
marshal(change, ?cashreg_receipt_session_changed(Payload)) ->
    [1, #{
        <<"change">>    => <<"session_changed">>,
        <<"payload">>   => marshal(session_change, Payload)
    }];

marshal(receipt_params, #cashreg_main_ReceiptParams{} = ReceiptParams) ->
    genlib_map:compact(#{
        <<"party">>     => marshal(party, ReceiptParams#cashreg_main_ReceiptParams.party),
        <<"operation">> => marshal(operation, ReceiptParams#cashreg_main_ReceiptParams.operation),
        <<"purchase">>  => marshal(purchase, ReceiptParams#cashreg_main_ReceiptParams.purchase),
        <<"payment">>   => marshal(payment, ReceiptParams#cashreg_main_ReceiptParams.payment),
        <<"metadata">>  => marshal(msgpack_value, ReceiptParams#cashreg_main_ReceiptParams.metadata)
    });

marshal(party, #cashreg_main_Party{} = Party) ->
    genlib_map:compact(#{
        <<"reg_name">>          => marshal(str, Party#cashreg_main_Party.registered_name),
        <<"reg_number">>        => marshal(str, Party#cashreg_main_Party.registered_number),
        <<"inn">>               => marshal(str, Party#cashreg_main_Party.inn),
        <<"actual_address">>    => marshal(str, Party#cashreg_main_Party.actual_address),
        <<"tax_system">>        => marshal(tax_system, Party#cashreg_main_Party.tax_system),
        <<"shop">>              => marshal(shop, Party#cashreg_main_Party.shop)
    });

marshal(tax_system, osn) ->
    <<"osn">>;
marshal(tax_system, usn_income) ->
    <<"usn_income">>;
marshal(tax_system, usn_income_outcome) ->
    <<"usn_income_outcome">>;
marshal(tax_system, envd) ->
    <<"envd">>;
marshal(tax_system, esn) ->
    <<"esn">>;
marshal(tax_system, patent) ->
    <<"patent">>;

marshal(shop, #cashreg_main_Shop{} = Shop) ->
    genlib_map:compact(#{
        <<"name">>        => marshal(str, Shop#cashreg_main_Shop.name),
        <<"description">> => marshal(str, Shop#cashreg_main_Shop.description),
        <<"location">>    => marshal(location, Shop#cashreg_main_Shop.location)
    });

marshal(location, {url, Url}) ->
    [<<"url">>, marshal(str, Url)];

marshal(operation, sell) ->
    <<"sell">>;
marshal(operation, sell_refund) ->
    <<"sell_refund">>;

marshal(purchase, #cashreg_main_Purchase{lines = Lines}) ->
    [marshal(purchase_line, Line) || Line <- Lines];

marshal(purchase_line, #cashreg_main_PurchaseLine{} = Line) ->
    genlib_map:compact(#{
        <<"product">> => marshal(str, Line#cashreg_main_PurchaseLine.product),
        <<"quantity">> => marshal(int, Line#cashreg_main_PurchaseLine.quantity),
        <<"price">> => marshal(cash, Line#cashreg_main_PurchaseLine.price),
        <<"tax">> => marshal(tax, Line#cashreg_main_PurchaseLine.tax)
    });

marshal(cash, #cashreg_main_Cash{} = Cash) ->
    [1, [
        marshal(int, Cash#cashreg_main_Cash.amount),
        marshal(currency, Cash#cashreg_main_Cash.currency)
    ]];

marshal(currency, #cashreg_main_Currency{} = Currency) ->
    #{
        <<"name">> => marshal(str, Currency#cashreg_main_Currency.name),
        <<"symbolic_code">> => marshal(str, Currency#cashreg_main_Currency.symbolic_code),
        <<"numeric_code">> => marshal(int, Currency#cashreg_main_Currency.numeric_code),
        <<"exponent">> => marshal(int, Currency#cashreg_main_Currency.exponent)
    };

marshal(tax, {vat, VAT}) ->
    [<<"vat">>, marshal(vat, VAT)];

marshal(vat, vat0) ->
    <<"vat0">>;
marshal(vat, vat10) ->
    <<"vat10">>;
marshal(vat, vat18) ->
    <<"vat18">>;
marshal(vat, vat110) ->
    <<"vat110">>;
marshal(vat, vat118) ->
    <<"vat118">>;

marshal(payment, #cashreg_main_Payment{} = Payment) ->
    #{
        <<"payment_method">> => marshal(payment_method, Payment#cashreg_main_Payment.payment_method),
        <<"cash">> => marshal(cash, Payment#cashreg_main_Payment.cash)
    };

marshal(payment_method, bank_card) ->
    <<"bank_card">>;

marshal(msgpack_value, undefined) ->
    undefined;
marshal(msgpack_value, MsgpackValue) ->
    hg_cashreg_msgpack_marshalling:unmarshal(MsgpackValue);

marshal(proxy, #cashreg_prxprv_Proxy{} = Proxy) ->
    #{
        <<"url">> => marshal(str, Proxy#cashreg_prxprv_Proxy.url),
        <<"options">> => marshal(map_str, Proxy#cashreg_prxprv_Proxy.options)
    };

marshal(receipt_reg_entry, #cashreg_main_ReceiptRegistrationEntry{} = ReceiptRegEntry) ->
    genlib_map:compact(#{
        <<"id">> => marshal(str, ReceiptRegEntry#cashreg_main_ReceiptRegistrationEntry.id),
        <<"metadata">> => marshal(msgpack_value, ReceiptRegEntry#cashreg_main_ReceiptRegistrationEntry.metadata)
    });

marshal(failure, {receipt_registration_failed, #cashreg_main_ReceiptRegistrationFailed{reason = ExternalFailure}}) ->
    [1, [<<"registration_failed">>, genlib_map:compact(#{
        <<"code">>          => marshal(str, ExternalFailure#cashreg_main_ExternalFailure.code),
        <<"description">>   => marshal(str, ExternalFailure#cashreg_main_ExternalFailure.description),
        <<"metadata">>      => marshal(msgpack_value, ExternalFailure#cashreg_main_ExternalFailure.metadata)
    })]];

marshal(session_change, ?cashreg_receipt_session_started()) ->
    [1, <<"started">>];
marshal(session_change, ?cashreg_receipt_session_finished(Result)) ->
    [1, [
        <<"finished">>,
        marshal(session_status, Result)
    ]];
marshal(session_change, ?cashreg_receipt_session_suspended(Tag)) ->
    [1, [
        <<"suspended">>,
        marshal(str, Tag)
    ]];
marshal(session_change, ?cashreg_receipt_proxy_st_changed(ProxySt)) ->
    [1, [
        <<"changed">>,
        marshal(msgpack_value, ProxySt)
    ]];

marshal(session_status, ?cashreg_receipt_session_succeeded()) ->
    <<"succeeded">>;
marshal(session_status, ?cashreg_receipt_session_failed(Failure)) ->
    [
        <<"failed">>,
        marshal(failure, Failure)
    ];

marshal(_, Other) ->
    Other.

%% Unmarshalling

unmarshal(Events) when is_list(Events) ->
    [unmarshal(Event) || Event <- Events];

unmarshal({ID, Dt, Payload}) ->
    {ID, Dt, unmarshal({list, changes}, Payload)}.

unmarshal({list, changes}, Changes) when is_list(Changes) ->
    [unmarshal(change, Change) || Change <- Changes];

unmarshal(change, [1, #{
    <<"change">>            := <<"created">>,
    <<"receipt_params">>    := ReceiptParams,
    <<"proxy">>             := Proxy
}]) ->
    ?cashreg_receipt_created(
        unmarshal(receipt_params, ReceiptParams),
        unmarshal(proxy, Proxy)
    );
unmarshal(change, [1, #{
    <<"change">>            := <<"registered">>,
    <<"receipt_reg_entry">> := ReceiptRegEntry
}]) ->
    ?cashreg_receipt_registered(
        unmarshal(receipt_reg_entry, ReceiptRegEntry)
    );
unmarshal(change, [1, #{
    <<"change">>    := <<"failed">>,
    <<"failure">>   := Failure
}]) ->
    ?cashreg_receipt_failed(
        unmarshal(failure, Failure)
    );
unmarshal(change, [1, #{
    <<"change">>    := <<"session_changed">>,
    <<"payload">>   := Payload
}]) ->
    ?cashreg_receipt_session_changed(
        unmarshal(session_change, Payload)
    );

unmarshal(receipt_params, #{
    <<"party">>     := Party,
    <<"operation">> := Operation,
    <<"purchase">>  := Purchase,
    <<"payment">>   := Payment
} = RP) ->
    Metadata = genlib_map:get(<<"metadata">>, RP),
    #cashreg_main_ReceiptParams{
        party = unmarshal(party, Party),
        operation = unmarshal(operation, Operation),
        purchase = unmarshal(purchase, Purchase),
        payment = unmarshal(payment, Payment),
        metadata = unmarshal(msgpack_value, Metadata)
    };

unmarshal(party, #{
    <<"reg_name">>          := RegName,
    <<"reg_number">>        := RegNumber,
    <<"inn">>               := Inn,
    <<"actual_address">>    := ActualAddress,
    <<"shop">>              := Shop
} = P) ->
    TaxSystem = genlib_map:get(<<"tax_system">>, P),
    #cashreg_main_Party{
        registered_name = unmarshal(str, RegName),
        registered_number = unmarshal(str, RegNumber),
        inn = unmarshal(str, Inn),
        actual_address = unmarshal(str, ActualAddress),
        tax_system = unmarshal(tax_system, TaxSystem),
        shop = unmarshal(shop, Shop)
    };

unmarshal(tax_system, <<"osn">>) ->
    osn;
unmarshal(tax_system, <<"usn_income">>) ->
    usn_income;
unmarshal(tax_system, <<"usn_income_outcome">>) ->
    usn_income_outcome;
unmarshal(tax_system, <<"envd">>) ->
    envd;
unmarshal(tax_system, <<"esn">>) ->
    esn;
unmarshal(tax_system, <<"patent">>) ->
    patent;

unmarshal(shop, #{
    <<"name">>        := Name,
    <<"location">>    := Location
} = S) ->
    Description = genlib_map:get(<<"description">>, S),
    #cashreg_main_Shop{
        name = unmarshal(str, Name),
        description = unmarshal(str, Description),
        location = unmarshal(location, Location)
    };

unmarshal(location, [<<"url">>, Url]) ->
    {url, unmarshal(str, Url)};

unmarshal(operation, <<"sell">>) ->
    sell;
unmarshal(operation, <<"sell_refund">>) ->
    sell_refund;

unmarshal(purchase, Lines) when is_list(Lines) ->
    #cashreg_main_Purchase{lines = [unmarshal(purchase_line, Line) || Line <- Lines]};

unmarshal(purchase_line, #{
    <<"product">> := Product,
    <<"quantity">> := Quantity,
    <<"price">> := Price
} = PL) ->
    Tax = genlib_map:get(<<"tax">>, PL),
    #cashreg_main_PurchaseLine{
        product = unmarshal(str, Product),
        quantity = unmarshal(int, Quantity),
        price = unmarshal(cash, Price),
        tax = unmarshal(tax, Tax)
    };

unmarshal(cash, [1, [Amount, Currency]]) ->
    #cashreg_main_Cash{
        amount = unmarshal(int, Amount),
        currency = unmarshal(currency, Currency)
    };

unmarshal(currency, #{
    <<"name">> := Name,
    <<"symbolic_code">> := SymbolicCode,
    <<"numeric_code">> := NumericCode,
    <<"exponent">> := Exponent
}) ->
    #cashreg_main_Currency{
        name = unmarshal(str, Name),
        symbolic_code = unmarshal(str, SymbolicCode),
        numeric_code = unmarshal(int, NumericCode),
        exponent = unmarshal(int, Exponent)
    };

unmarshal(tax, [<<"vat">>, VAT]) ->
    {vat, unmarshal(vat, VAT)};

unmarshal(vat, <<"vat0">>) ->
    vat0;
unmarshal(vat, <<"vat10">>) ->
    vat10;
unmarshal(vat, <<"vat18">>) ->
    vat18;
unmarshal(vat, <<"vat110">>) ->
    vat110;
unmarshal(vat, <<"vat118">>) ->
    vat118;

unmarshal(payment, #{
    <<"payment_method">> := PaymentMethod,
    <<"cash">> := Cash
}) ->
    #cashreg_main_Payment{
        payment_method = unmarshal(payment_method, PaymentMethod),
        cash = unmarshal(cash, Cash)
    };

unmarshal(payment_method, <<"bank_card">>) ->
    bank_card;

unmarshal(msgpack_value, undefined) ->
    undefined;
unmarshal(msgpack_value, MsgpackValue) ->
    hg_cashreg_msgpack_marshalling:marshal(MsgpackValue);

unmarshal(proxy, #{
    <<"url">> := Url,
    <<"options">> := Options
}) ->
    #cashreg_prxprv_Proxy{
        url = unmarshal(str, Url),
        options = unmarshal(map_str, Options)
    };

unmarshal(receipt_reg_entry, #{<<"id">> := Id} = RE) ->
    Metadata = genlib_map:get(<<"metadata">>, RE),
    #cashreg_main_ReceiptRegistrationEntry{
        id = unmarshal(str, Id),
        metadata = unmarshal(msgpack_value, Metadata)
    };

unmarshal(failure, [1, [<<"registration_failed">>, #{<<"code">> := Code} = RF]]) ->
    Description = genlib_map:get(<<"description">>, RF),
    Metadata = genlib_map:get(<<"metadata">>, RF),
    {receipt_registration_failed, #cashreg_main_ReceiptRegistrationFailed{
        reason = #cashreg_main_ExternalFailure{
            code = marshal(str, Code),
            description = marshal(str, Description),
            metadata = marshal(msgpack_value, Metadata)
        }
    }};

unmarshal(session_change, [1, <<"started">>]) ->
    ?cashreg_receipt_session_started();
unmarshal(session_change, [1, [<<"finished">>, Result]]) ->
    ?cashreg_receipt_session_finished(unmarshal(session_status, Result));
unmarshal(session_change, [1, [<<"suspended">>, Tag]]) ->
    ?cashreg_receipt_session_suspended(unmarshal(str, Tag));
unmarshal(session_change, [1, [<<"changed">>, ProxySt]]) ->
    ?cashreg_receipt_proxy_st_changed(unmarshal(msgpack_value, ProxySt));

unmarshal(session_status, <<"succeeded">>) ->
    ?cashreg_receipt_session_succeeded();
unmarshal(session_status, [<<"failed">>, Failure]) ->
    ?cashreg_receipt_session_failed(unmarshal(failure, Failure));

unmarshal(_, Other) ->
    Other.