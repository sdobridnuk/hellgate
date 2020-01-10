-module(hg_invoice_payment_chargeback).

-include("domain.hrl").
-include("payment_events.hrl").
-include_lib("damsel/include/dmsl_payment_processing_thrift.hrl").

-export([create/2]).
-export([cancel/2]).
-export([reject/3]).
-export([accept/3]).
-export([reopen/3]).

-export([merge_change/2]).
-export([create_cash_flow/3]).
-export([update_cash_flow/3]).
-export([finalise/3]).

-export([get/1]).

-export_type([st/0]).

-record(chargeback_st, {
    chargeback    :: undefined | chargeback(),
    cash_flow     :: undefined | cash_flow(),
    target_status :: undefined | chargeback_target_status()
}).

-type st()                       :: #chargeback_st{}.
-type chargeback_state()         :: st().
-type payment_state()            :: hg_invoice_payment:st().

-type cash_flow()                :: dmsl_domain_thrift:'FinalCashFlow'().
-type cash()                     :: dmsl_domain_thrift:'Cash'().

-type chargeback()               :: dmsl_domain_thrift:'InvoicePaymentChargeback'().
-type chargeback_id()            :: dmsl_domain_thrift:'InvoicePaymentChargebackID'().
-type chargeback_status()        :: dmsl_domain_thrift:'InvoicePaymentChargebackStatus'().
-type chargeback_stage()         :: dmsl_domain_thrift:'InvoicePaymentChargebackStage'().

-type chargeback_target_status() :: chargeback_status() | undefined.

-type chargeback_params()        :: dmsl_payment_processing_thrift:'InvoicePaymentChargebackParams'().
-type accept_params()            :: dmsl_payment_processing_thrift:'InvoicePaymentChargebackAcceptParams'().
-type reject_params()            :: dmsl_payment_processing_thrift:'InvoicePaymentChargebackRejectParams'().
-type reopen_params()            :: dmsl_payment_processing_thrift:'InvoicePaymentChargebackReopenParams'().

-type chargeback_change()        :: dmsl_payment_processing_thrift:'InvoicePaymentChargebackChangePayload'().

-type result()                   :: {events(), action()}.
-type events()                   :: [event()].
-type event()                    :: dmsl_payment_processing_thrift:'InvoicePaymentChangePayload'().
-type action()                   :: hg_machine_action:t().
-type machine_result()           :: hg_invoice_payment:machine_result().

-spec get(chargeback_state()) ->
    chargeback().
get(#chargeback_st{chargeback = Chargeback}) ->
    Chargeback.

%%----------------------------------------------------------------------------
%% @doc
%% `create/3` creates a chargeback. A chargeback will not be created if
%% another one is already pending, and it will block `refunds` from being
%% created as well.
%%
%% Key parameters:
%%    `levy`: the amount of cash to be levied from the merchant.
%%    `body`: The sum of the chargeback.
%%            Will default to full amount if undefined.
%% @end
%%----------------------------------------------------------------------------
-spec create(payment_state(), chargeback_params()) ->
    {chargeback(), result()} | no_return().
create(PaymentState, ChargebackParams) ->
    do_create(PaymentState, ChargebackParams).

%%----------------------------------------------------------------------------
%% @doc
%% `cancel/3` will cancel the chargeback with the given ID. All funds
%% will be trasferred back to the merchant as a result of this operation.
%% @end
%%----------------------------------------------------------------------------
-spec cancel(chargeback_id(), payment_state()) ->
    {ok, result()} | no_return().
cancel(ChargebackID, PaymentState) ->
    do_cancel(ChargebackID, PaymentState).

%%----------------------------------------------------------------------------
%% @doc
%% `reject/3` will reject the chargeback with the given ID, implying that no
%% sufficient evidence has been found to support the chargeback claim.
%%
%% Key parameters:
%%    `levy`: the amount of cash to be levied from the merchant.
%% @end
%%----------------------------------------------------------------------------
-spec reject(chargeback_id(), payment_state(), reject_params()) ->
    {ok, result()} | no_return().
reject(ChargebackID, PaymentState, RejectParams) ->
    do_reject(ChargebackID, PaymentState, RejectParams).

%%----------------------------------------------------------------------------
%% @doc
%% `accept/4` will accept the chargeback with the given ID, implying that
%% sufficient evidence has been found to support the chargeback claim. The
%% cost of the chargeback will be deducted from the merchant's account.
%%
%% Key parameters:
%%    `levy`: the amount of cash to be levied from the merchant.
%%            Will not change if undefined.
%%    `body`: The sum of the chargeback.
%%            Will not change if undefined.
%% @end
%%----------------------------------------------------------------------------
-spec accept(chargeback_id(), payment_state(), accept_params()) ->
    {ok, result()} | no_return().
accept(ChargebackID, PaymentState, AcceptParams) ->
    do_accept(ChargebackID, PaymentState, AcceptParams).

%%----------------------------------------------------------------------------
%% @doc
%% `reopen/4` will reopen the chargeback with the given ID, implying that
%% the party that initiated the chargeback was not satisfied with the result
%% and demands a new investigation. The chargeback progresses to its next
%% stage as a result of this action.
%%
%% Key parameters:
%%    `levy`: the amount of cash to be levied from the merchant.
%%    `body`: The sum of the chargeback. Will not change if undefined.
%% @end
%%----------------------------------------------------------------------------
-spec reopen(chargeback_id(), payment_state(), reopen_params()) ->
    {ok, result()} | no_return().
reopen(ChargebackID, PaymentState, ReopenParams) ->
    do_reopen(ChargebackID, PaymentState, ReopenParams).

-spec merge_change(chargeback_change(), chargeback_state()) ->
    chargeback_state().
merge_change(Change, ChargebackState) ->
    do_merge_change(Change, ChargebackState).

-spec create_cash_flow(chargeback_id(), action(), payment_state()) ->
    machine_result() | no_return().
create_cash_flow(ChargebackID, _Action, PaymentState) ->
    do_create_cash_flow(hg_invoice_payment:get_chargeback_state(ChargebackID, PaymentState), PaymentState).

-spec update_cash_flow(chargeback_id(), action(), payment_state()) ->
    machine_result() | no_return().
update_cash_flow(ChargebackID, _Action, PaymentState) ->
    do_update_cash_flow(hg_invoice_payment:get_chargeback_state(ChargebackID, PaymentState), PaymentState).

-spec finalise(chargeback_id(), action(), payment_state()) ->
    machine_result() | no_return().
finalise(ChargebackID, Action, PaymentState) ->
    do_finalise(hg_invoice_payment:get_chargeback_state(ChargebackID, PaymentState), Action, PaymentState).

%% Private

-spec do_create(payment_state(), chargeback_params()) ->
    {chargeback(), result()} | no_return().
do_create(PaymentState, ChargebackParams) ->
    Chargeback = build_chargeback(PaymentState, ChargebackParams),
    ID         = get_id(Chargeback),
    Action     = hg_machine_action:instant(),
    CBCreated  = ?chargeback_created(Chargeback),
    CBEvent    = ?chargeback_ev(ID, CBCreated),
    Result     = {[CBEvent], Action},
    {Chargeback, Result}.

-spec do_cancel(chargeback_id(), payment_state()) ->
    {ok, result()} | no_return().
do_cancel(ID, PaymentState) ->
    ChargebackState = hg_invoice_payment:get_chargeback_state(ID, PaymentState),
    _               = validate_chargeback_is_pending(ChargebackState),
    _               = validate_stage_is_chargeback(ChargebackState),
    Result          = build_cancel_result(ChargebackState, PaymentState),
    {ok, Result}.

-spec do_reject(chargeback_id(), payment_state(), reject_params()) ->
    {ok, result()} | no_return().
do_reject(ID, PaymentState, RejectParams) ->
    ChargebackState = hg_invoice_payment:get_chargeback_state(ID, PaymentState),
    _               = validate_chargeback_is_pending(ChargebackState),
    Result          = build_reject_result(ChargebackState, PaymentState, RejectParams),
    {ok, Result}.

-spec do_accept(chargeback_id(), payment_state(), accept_params()) ->
    {ok, result()} | no_return().
do_accept(ID, PaymentState, AcceptParams) ->
    ChargebackState = hg_invoice_payment:get_chargeback_state(ID, PaymentState),
    _               = validate_chargeback_is_pending(ChargebackState),
    Result          = build_accept_result(ChargebackState, PaymentState, AcceptParams),
    {ok, Result}.

-spec do_reopen(chargeback_id(), payment_state(), reopen_params()) ->
    {ok, result()} | no_return().
do_reopen(ID, PaymentState, ReopenParams) ->
    ChargebackState = hg_invoice_payment:get_chargeback_state(ID, PaymentState),
    _               = validate_chargeback_is_rejected(ChargebackState),
    _               = validate_not_arbitration(ChargebackState),
    Result          = build_reopen_result(ChargebackState, PaymentState, ReopenParams),
    {ok, Result}.

-spec do_merge_change(chargeback_change(), chargeback_state()) ->
    chargeback_state().
do_merge_change(?chargeback_created(Chargeback), ChargebackState) ->
    set(Chargeback, ChargebackState);
do_merge_change(?chargeback_levy_changed(Levy), ChargebackState) ->
    set_levy(Levy, ChargebackState);
do_merge_change(?chargeback_body_changed(Body), ChargebackState) ->
    set_body(Body, ChargebackState);
do_merge_change(?chargeback_stage_changed(Stage), ChargebackState) ->
    set_stage(Stage, ChargebackState);
do_merge_change(?chargeback_target_status_changed(Status), ChargebackState) ->
    set_target_status(Status, ChargebackState);
do_merge_change(?chargeback_status_changed(Status), ChargebackState) ->
    set_target_status(undefined, set_status(Status, ChargebackState));
do_merge_change(?chargeback_cash_flow_changed(CashFlow), ChargebackState) ->
    set_cash_flow(CashFlow, ChargebackState).

-spec do_create_cash_flow(chargeback_state(), payment_state()) ->
    machine_result() | no_return().
do_create_cash_flow(ChargebackState, PaymentState) ->
    FinalCashFlow   = build_chargeback_cash_flow(ChargebackState, PaymentState),
    CashFlowPlan    = {1, FinalCashFlow},
    _               = prepare_cash_flow(ChargebackState, CashFlowPlan, PaymentState),
    CFEvent         = ?chargeback_cash_flow_changed(FinalCashFlow),
    CBEvent         = ?chargeback_ev(get_id(ChargebackState), CFEvent),
    Action0         = hg_machine_action:new(),
    {done, {[CBEvent], Action0}}.

-spec do_update_cash_flow(chargeback_state(), payment_state()) ->
    machine_result() | no_return().
do_update_cash_flow(ChargebackState = #chargeback_st{cash_flow = CashFlow, target_status = Status},
                    PaymentState) ->
    FinalCashFlow = build_chargeback_cash_flow(ChargebackState, PaymentState),
    Stage = get_stage(ChargebackState),
    case {Stage, Status} of
        {?chargeback_stage_chargeback(), _} ->
            CashFlowPlan = {1, FinalCashFlow},
            _            = prepare_cash_flow(ChargebackState, CashFlowPlan, PaymentState),
            CFEvent      = ?chargeback_cash_flow_changed(FinalCashFlow),
            CBEvent      = ?chargeback_ev(get_id(ChargebackState), CFEvent),
            Action       = hg_machine_action:instant(),
            {done, {[CBEvent], Action}};
        {?chargeback_stage_pre_arbitration(), ?chargeback_status_pending()} ->
            RevertedCF   = hg_cashflow:revert([lists:last(CashFlow)]),
            NewCF        = lists:droplast(CashFlow) ++ RevertedCF ++ FinalCashFlow,
            CashFlowPlan = {1, NewCF},
            _            = prepare_cash_flow(ChargebackState, CashFlowPlan, PaymentState),
            CFEvent      = ?chargeback_cash_flow_changed(NewCF),
            CBEvent      = ?chargeback_ev(get_id(ChargebackState), CFEvent),
            Action       = hg_machine_action:instant(),
            {done, {[CBEvent], Action}};
        _ ->
            RevertedCF   = hg_cashflow:revert([lists:last(CashFlow)]),
            NewCF        = CashFlow ++ RevertedCF ++ FinalCashFlow,
            CashFlowPlan = {1, NewCF},
            _            = prepare_cash_flow(ChargebackState, CashFlowPlan, PaymentState),
            CFEvent      = ?chargeback_cash_flow_changed(NewCF),
            CBEvent      = ?chargeback_ev(get_id(ChargebackState), CFEvent),
            Action       = hg_machine_action:instant(),
            {done, {[CBEvent], Action}}
    end.

-spec do_finalise(chargeback_state(), action(), payment_state()) ->
    machine_result() | no_return().
do_finalise(ChargebackState = #chargeback_st{target_status = ?chargeback_status_pending() = Status},
            Action,
            _PaymentState) ->
    StatusEvent = ?chargeback_status_changed(Status),
    CBEvent     = ?chargeback_ev(get_id(ChargebackState), StatusEvent),
    {done, {[CBEvent], Action}};
do_finalise(ChargebackState = #chargeback_st{target_status = ?chargeback_status_rejected() = Status},
            Action,
            PaymentState) ->
    _           = commit_cash_flow(ChargebackState, PaymentState),
    StatusEvent = ?chargeback_status_changed(Status),
    CBEvent     = ?chargeback_ev(get_id(ChargebackState), StatusEvent),
    {done, {[CBEvent], Action}};
do_finalise(ChargebackState = #chargeback_st{target_status = ?chargeback_status_accepted() = Status},
            Action,
            PaymentState) ->
    _                = commit_cash_flow(ChargebackState, PaymentState),
    StatusEvent      = ?chargeback_status_changed(Status),
    CBEvent          = ?chargeback_ev(get_id(ChargebackState), StatusEvent),
    MaybeChargedBack = maybe_set_charged_back_status(ChargebackState, PaymentState),
    {done, {[CBEvent] ++ MaybeChargedBack, Action}}.

-spec build_chargeback(payment_state(), chargeback_params()) ->
    chargeback() | no_return().
build_chargeback(PaymentState, ?chargeback_params(Levy, ParamsBody, Reason)) ->
    Revision      = hg_domain:head(),
    Payment       = hg_invoice_payment:get_payment(PaymentState),
    PaymentOpts   = hg_invoice_payment:get_opts(PaymentState),
    PartyRevision = get_opts_party_revision(PaymentOpts),
    _             = validate_no_pending_chargebacks(PaymentState),
    _             = validate_payment_status(captured, Payment),
    FinalBody     = define_body(ParamsBody, Payment),
    _             = validate_levy(Levy, Payment),
    _             = validate_body_amount(FinalBody, PaymentState),
    #domain_InvoicePaymentChargeback{
        id              = construct_id(PaymentState),
        created_at      = hg_datetime:format_now(),
        stage           = ?chargeback_stage_chargeback(),
        status          = ?chargeback_status_pending(),
        domain_revision = Revision,
        party_revision  = PartyRevision,
        reason          = Reason,
        levy            = Levy,
        body            = FinalBody
    }.

-spec build_cancel_result(chargeback_state(), payment_state()) ->
    result() | no_return().
build_cancel_result(ChargebackState = #chargeback_st{chargeback = #domain_InvoicePaymentChargeback{id = ID}},
                    PaymentState) ->
    _      = rollback_cash_flow(ChargebackState, PaymentState),
    Action = hg_machine_action:new(),
    Status = ?chargeback_status_cancelled(),
    Change = ?chargeback_status_changed(Status),
    Events = [?chargeback_ev(ID, Change)],
    {Events, Action}.

-spec build_reject_result(chargeback_state(), payment_state(), reject_params()) ->
    result() | no_return().
build_reject_result(ChargebackState = #chargeback_st{chargeback =
                        #domain_InvoicePaymentChargeback{id = ID, levy = Levy}},
                    PaymentState,
                    ?reject_params(Levy)) ->
    _      = commit_cash_flow(ChargebackState, PaymentState),
    Action = hg_machine_action:new(),
    Status = ?chargeback_status_rejected(),
    Change = ?chargeback_status_changed(Status),
    Events = [?chargeback_ev(ID, Change)],
    {Events, Action};
build_reject_result(ChargebackState = #chargeback_st{chargeback =
                        #domain_InvoicePaymentChargeback{id = ID, levy = Levy}},
                    PaymentState,
                    ?reject_params(ParamsLevy)) ->
    FinalLevy    = define_params_levy(ParamsLevy, Levy),
    _            = rollback_cash_flow(ChargebackState, PaymentState),
    Action       = hg_machine_action:instant(),
    Status       = ?chargeback_status_rejected(),
    LevyChange   = ?chargeback_levy_changed(FinalLevy),
    StatusChange = ?chargeback_target_status_changed(Status),
    Changes      = [LevyChange, StatusChange],
    Events       = wrap_chargeback_events(ID, Changes),
    {Events, Action}.

-spec build_accept_result(chargeback_state(), payment_state(), accept_params()) ->
    result() | no_return().
build_accept_result(ChargebackState = #chargeback_st{chargeback =
                        #domain_InvoicePaymentChargeback{id = ID, body = Body, levy = Levy}},
                    PaymentState,
                    ?accept_params(ParamsLevy, ParamsBody)) when (ParamsLevy =:= undefined orelse
                                                                  ParamsLevy =:= Levy)     andalso
                                                                 (ParamsBody =:= undefined orelse
                                                                  ParamsBody =:= Body) ->
    _         = commit_cash_flow(ChargebackState, PaymentState),
    Action    = hg_machine_action:new(),
    Status    = ?chargeback_status_accepted(),
    Change    = ?chargeback_status_changed(Status),
    Events    = [?chargeback_ev(ID, Change)] ++ maybe_set_charged_back_status(ChargebackState, PaymentState),
    {Events, Action};
build_accept_result(ChargebackState = #chargeback_st{chargeback =
                        #domain_InvoicePaymentChargeback{id = ID, body = Body, levy = Levy}},
                    PaymentState,
                    ?accept_params(ParamsLevy, ParamsBody)) ->
    FinalBody     = define_params_body(ParamsBody, Body),
    FinalLevy     = define_params_levy(ParamsLevy, Levy),
    _             = validate_body_amount(FinalBody, PaymentState),
    _             = rollback_cash_flow(ChargebackState, PaymentState),
    Action        = hg_machine_action:instant(),
    Status        = ?chargeback_status_accepted(),
    BodyChange    = body_change(FinalBody, Body),
    LevyChange    = levy_change(FinalLevy, Levy),
    StatusChange  = [?chargeback_target_status_changed(Status)],
    Changes       = lists:append([BodyChange, LevyChange, StatusChange]),
    Events        = wrap_chargeback_events(ID, Changes),
    {Events, Action}.

-spec build_reopen_result(chargeback_state(), payment_state(), reopen_params()) ->
    result() | no_return().
build_reopen_result(ChargebackState = #chargeback_st{chargeback =
                        #domain_InvoicePaymentChargeback{id = ID, body = Body, levy = Levy}},
                    PaymentState,
                    ?reopen_params(ParamsLevy, ParamsBody)) ->
    FinalBody     = define_params_body(ParamsBody, Body),
    _             = validate_body_amount(FinalBody, PaymentState),
    FinalLevy     = define_params_levy(ParamsLevy, Levy),
    ID            = get_id(ChargebackState),
    Stage         = get_next_stage(ChargebackState),
    Action        = hg_machine_action:instant(),
    Status        = ?chargeback_status_pending(),
    StageChange   = [?chargeback_stage_changed(Stage)],
    BodyChange    = body_change(FinalBody, Body),
    LevyChange    = levy_change(FinalLevy, Levy),
    StatusChange  = [?chargeback_target_status_changed(Status)],
    Changes       = lists:append([StageChange, BodyChange, LevyChange, StatusChange]),
    Events        = wrap_chargeback_events(ID, Changes),
    % Events        = [?chargeback_ev(ID, StageChange), ?chargeback_ev(ID, Change)],
    {Events, Action}.

-spec build_chargeback_cash_flow(chargeback_state(), payment_state()) ->
    cash_flow() | no_return().
build_chargeback_cash_flow(ChargebackState, PaymentState) ->
    Revision        = get_revision(ChargebackState),
    Payment         = hg_invoice_payment:get_payment(PaymentState),
    PaymentOpts     = hg_invoice_payment:get_opts(PaymentState),
    Invoice         = get_opts_invoice(PaymentOpts),
    Party           = get_opts_party(PaymentOpts),
    ShopID          = get_invoice_shop_id(Invoice),
    CreatedAt       = get_invoice_created_at(Invoice),
    Shop            = hg_party:get_shop(ShopID, Party),
    ContractID      = get_shop_contract_id(Shop),
    Contract        = hg_party:get_contract(ContractID, Party),
    _               = validate_contract_active(Contract),
    TermSet         = hg_party:get_terms(Contract, CreatedAt, Revision),
    ServiceTerms    = get_merchant_chargeback_terms(TermSet),
    VS0             = collect_validation_varset(Party, Shop, Payment, ChargebackState),
    Route           = hg_invoice_payment:get_route(PaymentState),
    PaymentsTerms   = hg_routing:get_payments_terms(Route, Revision),
    ProviderTerms   = get_provider_chargeback_terms(PaymentsTerms, Payment),
    VS1             = validate_chargeback(ServiceTerms, Payment, VS0, Revision),
    CashFlow        = collect_chargeback_cash_flow(ProviderTerms, VS1, Revision),
    PmntInstitution = get_payment_institution(Contract, Revision),
    Provider        = get_route_provider(Route, Revision),
    AccountMap      = collect_account_map(Payment, Shop, PmntInstitution, Provider, VS1, Revision),
    Context         = build_cash_flow_context(ChargebackState),
    hg_cashflow:finalize(CashFlow, Context, AccountMap).

collect_chargeback_cash_flow(ProviderTerms, VS, Revision) ->
    #domain_PaymentChargebackProvisionTerms{cash_flow = ProviderCashflowSelector} = ProviderTerms,
    reduce_selector(provider_chargeback_cash_flow, ProviderCashflowSelector, VS, Revision).

collect_account_map(
    Payment,
    #domain_Shop{account = MerchantAccount},
    PaymentInstitution,
    #domain_Provider{accounts = ProviderAccounts},
    VS,
    Revision
) ->
    PaymentCash     = get_payment_cost(Payment),
    Currency        = get_cash_currency(PaymentCash),
    ProviderAccount = choose_provider_account(Currency, ProviderAccounts),
    SystemAccount   = hg_payment_institution:get_system_account(Currency, VS, Revision, PaymentInstitution),
    M = #{
        {merchant , settlement} => MerchantAccount#domain_ShopAccount.settlement     ,
        {merchant , guarantee } => MerchantAccount#domain_ShopAccount.guarantee      ,
        {provider , settlement} => ProviderAccount#domain_ProviderAccount.settlement ,
        {system   , settlement} => SystemAccount#domain_SystemAccount.settlement     ,
        {system   , subagent  } => SystemAccount#domain_SystemAccount.subagent
    },
    % External account probably can be optional for some payments
    case choose_external_account(Currency, VS, Revision) of
        #domain_ExternalAccount{income = Income, outcome = Outcome} ->
            M#{
                {external, income} => Income,
                {external, outcome} => Outcome
            };
        undefined ->
            M
    end.

build_cash_flow_context(ChargebackState) ->
    #{operation_amount => get_levy(ChargebackState)}.

construct_id(PaymentState) ->
    Chargebacks = hg_invoice_payment:get_chargebacks(PaymentState),
    MaxID       = lists:foldl(fun find_max_id/2, 0, Chargebacks),
    genlib:to_binary(MaxID + 1).

find_max_id(#domain_InvoicePaymentChargeback{id = ID}, Max) ->
    IntID = genlib:to_int(ID),
    erlang:max(IntID, Max).

validate_chargeback(Terms, Payment, VS, Revision) ->
    PaymentTool           = get_payment_tool(Payment),
    PaymentMethodSelector = get_chargeback_payment_method_selector(Terms),
    PMs                   = reduce_selector(payment_methods, PaymentMethodSelector, VS, Revision),
    _                     = ordsets:is_element(hg_payment_tool:get_method(PaymentTool), PMs) orelse
                            throw(#'InvalidRequest'{errors = [<<"Invalid payment method">>]}),
    VS#{payment_tool => PaymentTool}.

reduce_selector(Name, Selector, VS, Revision) ->
    case hg_selector:reduce(Selector, VS, Revision) of
        {value, V} ->
            V;
        Ambiguous ->
            error({misconfiguration, {'Could not reduce selector to a value', {Name, Ambiguous}}})
    end.

choose_provider_account(Currency, Accounts) ->
    case maps:find(Currency, Accounts) of
        {ok, Account} ->
            Account;
        error ->
            error({misconfiguration, {'No provider account for a given currency', Currency}})
    end.

choose_external_account(Currency, VS, Revision) ->
    Globals = hg_domain:get(Revision, {globals, #domain_GlobalsRef{}}),
    ExternalAccountSetSelector = Globals#domain_Globals.external_account_set,
    case hg_selector:reduce(ExternalAccountSetSelector, VS, Revision) of
        {value, ExternalAccountSetRef} ->
            ExternalAccountSet = hg_domain:get(Revision, {external_account_set, ExternalAccountSetRef}),
            genlib_map:get(
                Currency,
                ExternalAccountSet#domain_ExternalAccountSet.accounts
            );
        _ ->
            undefined
    end.

get_provider_chargeback_terms(#domain_PaymentsProvisionTerms{chargebacks = undefined}, Payment) ->
    error({misconfiguration, {'No chargeback terms for a payment', Payment}});
get_provider_chargeback_terms(#domain_PaymentsProvisionTerms{chargebacks = Terms}, _Payment) ->
    Terms.

get_merchant_chargeback_terms(#domain_TermSet{payments = PaymentsTerms}) ->
    get_merchant_chargeback_terms(PaymentsTerms);
get_merchant_chargeback_terms(#domain_PaymentsServiceTerms{chargebacks = Terms}) when Terms /= undefined ->
    Terms;
get_merchant_chargeback_terms(#domain_PaymentsServiceTerms{chargebacks = undefined}) ->
    throw(#payproc_OperationNotPermitted{}).

define_body(undefined, #domain_InvoicePayment{cost = Cost}) ->
    Cost;
define_body(?cash(_, SymCode) = Cash, #domain_InvoicePayment{cost = ?cash(_, SymCode)}) ->
    Cash;
define_body(?cash(_, SymCode), _Payment) ->
    throw(#payproc_InconsistentChargebackCurrency{currency = SymCode}).

define_params_body(undefined, CurrentBody) ->
    CurrentBody;
define_params_body(?cash(_, SymCode) = Body, ?cash(_, SymCode) = _CurrentBody) ->
    Body;
define_params_body(?cash(_, SymCode), _CurrentBody) ->
    throw(#payproc_InconsistentChargebackCurrency{currency = SymCode}).

define_params_levy(undefined, CurrentLevy) ->
    CurrentLevy;
define_params_levy(?cash(_, SymCode) = Levy, ?cash(_, SymCode) = _CurrentLevy) ->
    Levy;
define_params_levy(?cash(_, SymCode), _CurrentLevy) ->
    throw(#payproc_InconsistentChargebackCurrency{currency = SymCode}).

prepare_cash_flow(ChargebackState, CashFlowPlan, PaymentState) ->
    PlanID = construct_chargeback_plan_id(ChargebackState, PaymentState),
    hg_accounting:plan(PlanID, [CashFlowPlan]).

commit_cash_flow(ChargebackState, PaymentState) ->
    CashFlowPlan = get_cash_flow_plan(ChargebackState),
    PlanID       = construct_chargeback_plan_id(ChargebackState, PaymentState),
    hg_accounting:commit(PlanID, [CashFlowPlan]).

rollback_cash_flow(ChargebackState, PaymentState) ->
    CashFlowPlan = get_cash_flow_plan(ChargebackState),
    PlanID       = construct_chargeback_plan_id(ChargebackState, PaymentState),
    hg_accounting:rollback(PlanID, [CashFlowPlan]).

construct_chargeback_plan_id(ChargebackState, PaymentState) ->
    PaymentOpts  = hg_invoice_payment:get_opts(PaymentState),
    Payment      = hg_invoice_payment:get_payment(PaymentState),
    ChargebackID = get_id(ChargebackState),
    {Stage, _}   = get_stage(ChargebackState),
    TargetStatus = get_target_status(ChargebackState),
    Status       = case {TargetStatus, Stage} of
        {{StatusType, _}, Stage} -> StatusType;
        {undefined, chargeback}  -> initial;
        {undefined, Stage}       -> pending
    end,
    hg_utils:construct_complex_id([
        get_opts_invoice_id(PaymentOpts),
        get_payment_id(Payment),
        {chargeback, ChargebackID},
        genlib:to_binary(Stage),
        genlib:to_binary(Status)
    ]).

maybe_set_charged_back_status(ChargebackState, PaymentState) ->
    Body = get_body(ChargebackState),
    InterimPaymentAmount = hg_invoice_payment:get_remaining_payment_balance(PaymentState),
    case hg_cash:sub(InterimPaymentAmount, Body) of
        ?cash(Amount, _) when Amount =:= 0 ->
            [?payment_status_changed(?charged_back())];
        ?cash(Amount, _) when Amount > 0 ->
            []
    end.

collect_validation_varset(Party, Shop, Payment, ChargebackState) ->
    #domain_Party{id = PartyID} = Party,
    #domain_Shop{
        id       = ShopID,
        category = Category,
        account  = #domain_ShopAccount{currency = Currency}
    } = Shop,
    % Cost = hg_cash:add(get_levy(ChargebackState), get_body(ChargebackState)),
    #{
        party_id     => PartyID,
        shop_id      => ShopID,
        category     => Category,
        currency     => Currency,
        cost         => get_levy(ChargebackState),
        payment_tool => get_payment_tool(Payment)
    }.

%% Validations

validate_levy(?cash(_, SymCode), #domain_InvoicePayment{cost = ?cash(_, SymCode)}) ->
    ok;
validate_levy(?cash(_, SymCode), _Payment) ->
    throw(#payproc_InconsistentChargebackCurrency{currency = SymCode}).

validate_stage_is_chargeback(#chargeback_st{chargeback = Chargeback}) ->
    validate_stage_is_chargeback(Chargeback);
validate_stage_is_chargeback(#domain_InvoicePaymentChargeback{stage = ?chargeback_stage_chargeback()}) ->
    ok;
validate_stage_is_chargeback(#domain_InvoicePaymentChargeback{stage = Stage}) ->
    throw(#payproc_InvoicePaymentChargebackInvalidStage{stage = Stage}).

validate_not_arbitration(#chargeback_st{chargeback = Chargeback}) ->
    validate_not_arbitration(Chargeback);
validate_not_arbitration(#domain_InvoicePaymentChargeback{stage = ?chargeback_stage_arbitration()}) ->
    throw(#payproc_InvoicePaymentChargebackCannotReopenAfterArbitration{});
validate_not_arbitration(#domain_InvoicePaymentChargeback{}) ->
    ok.

validate_chargeback_is_rejected(#chargeback_st{chargeback = Chargeback}) ->
    validate_chargeback_is_rejected(Chargeback);
validate_chargeback_is_rejected(#domain_InvoicePaymentChargeback{status = ?chargeback_status_rejected()}) ->
    ok;
validate_chargeback_is_rejected(#domain_InvoicePaymentChargeback{status = Status}) ->
    throw(#payproc_InvoicePaymentChargebackInvalidStatus{status = Status}).

validate_chargeback_is_pending(#chargeback_st{chargeback = Chargeback}) ->
    validate_chargeback_is_pending(Chargeback);
validate_chargeback_is_pending(#domain_InvoicePaymentChargeback{status = ?chargeback_status_pending()}) ->
    ok;
validate_chargeback_is_pending(#domain_InvoicePaymentChargeback{status = Status}) ->
    throw(#payproc_InvoicePaymentChargebackInvalidStatus{status = Status}).

validate_payment_status(Status, #domain_InvoicePayment{status = {Status, _}}) ->
    ok;
validate_payment_status(_, #domain_InvoicePayment{status = Status}) ->
    throw(#payproc_InvalidPaymentStatus{status = Status}).

validate_body_amount(Cash, PaymentState) ->
    InterimPaymentAmount = hg_invoice_payment:get_remaining_payment_balance(PaymentState),
    PaymentAmount = hg_cash:sub(InterimPaymentAmount, Cash),
    validate_remaining_payment_amount(PaymentAmount, PaymentState).

validate_remaining_payment_amount(?cash(Amount, _), _PaymentState) when Amount >= 0 ->
    ok;
validate_remaining_payment_amount(?cash(Amount, _), PaymentState) when Amount < 0 ->
    Maximum = hg_invoice_payment:get_remaining_payment_balance(PaymentState),
    throw(#payproc_InvoicePaymentAmountExceeded{maximum = Maximum}).

validate_contract_active(#domain_Contract{status = {active, _}}) ->
    ok;
validate_contract_active(#domain_Contract{status = Status}) ->
    throw(#payproc_InvalidContractStatus{status = Status}).

validate_no_pending_chargebacks(PaymentState) ->
    Chargebacks        = hg_invoice_payment:get_chargebacks(PaymentState),
    PendingChargebacks = lists:filter(fun filter_pending/1, Chargebacks),
    case length(PendingChargebacks) of
        0 -> ok;
        _ -> throw(#payproc_InvoicePaymentChargebackPending{})
    end.

filter_pending(#domain_InvoicePaymentChargeback{status = Status}) ->
    case Status of
        ?chargeback_status_pending() -> true;
        _NotPending                  -> false
    end.

%% Getters

-spec get_id(chargeback_state() | chargeback()) ->
    chargeback_id().
get_id(#chargeback_st{chargeback = Chargeback}) ->
    get_id(Chargeback);
get_id(#domain_InvoicePaymentChargeback{id = ID}) ->
    ID.

-spec get_target_status(chargeback_state()) ->
    chargeback_target_status().
get_target_status(#chargeback_st{target_status = TargetStatus}) ->
    TargetStatus.

-spec get_cash_flow_plan(chargeback_state()) ->
    hg_accounting:batch().
get_cash_flow_plan(#chargeback_st{cash_flow = CashFlow}) ->
    {1, CashFlow}.

-spec get_body(chargeback_state() | chargeback()) ->
    cash().
get_body(#chargeback_st{chargeback = Chargeback}) ->
    get_body(Chargeback);
get_body(#domain_InvoicePaymentChargeback{body = Body}) ->
    Body.

-spec get_revision(chargeback_state() | chargeback()) ->
    hg_domain:revision().
get_revision(#chargeback_st{chargeback = Chargeback}) ->
    get_revision(Chargeback);
get_revision(#domain_InvoicePaymentChargeback{domain_revision = Revision}) ->
    Revision.

-spec get_levy(chargeback_state() | chargeback()) ->
    cash().
get_levy(#chargeback_st{chargeback = Chargeback}) ->
    get_levy(Chargeback);
get_levy(#domain_InvoicePaymentChargeback{levy = Levy}) ->
    Levy.

-spec get_stage(chargeback_state() | chargeback()) ->
    chargeback_stage().
get_stage(#chargeback_st{chargeback = Chargeback}) ->
    get_stage(Chargeback);
get_stage(#domain_InvoicePaymentChargeback{stage = Stage}) ->
    Stage.

-spec get_next_stage(chargeback_state() | chargeback()) ->
    ?chargeback_stage_pre_arbitration() | ?chargeback_stage_arbitration().
get_next_stage(#chargeback_st{chargeback = Chargeback}) ->
    get_next_stage(Chargeback);
get_next_stage(#domain_InvoicePaymentChargeback{stage = ?chargeback_stage_chargeback()}) ->
    ?chargeback_stage_pre_arbitration();
get_next_stage(#domain_InvoicePaymentChargeback{stage = ?chargeback_stage_pre_arbitration()}) ->
    ?chargeback_stage_arbitration().

%% Setters

-spec set(chargeback(), chargeback_state() | undefined) ->
    chargeback_state().
set(Chargeback, undefined) ->
    #chargeback_st{chargeback = Chargeback};
set(Chargeback, ChargebackState = #chargeback_st{}) ->
    ChargebackState#chargeback_st{chargeback = Chargeback}.

-spec set_cash_flow(cash_flow(), chargeback_state()) ->
    chargeback_state().
set_cash_flow(CashFlow, ChargebackState = #chargeback_st{}) ->
    ChargebackState#chargeback_st{cash_flow = CashFlow}.

-spec set_target_status(chargeback_status() | undefined, chargeback_state()) ->
    chargeback_state().
set_target_status(TargetStatus, #chargeback_st{} = ChargebackState) ->
    ChargebackState#chargeback_st{target_status = TargetStatus}.

-spec set_status(chargeback_status(), chargeback_state()) ->
    chargeback_state().
set_status(Status, #chargeback_st{chargeback = Chargeback} = ChargebackState) ->
    ChargebackState#chargeback_st{
        chargeback = Chargeback#domain_InvoicePaymentChargeback{status = Status}
    }.

-spec set_body(cash() | undefined, chargeback_state()) ->
    chargeback_state().
set_body(undefined, ChargebackState) ->
    ChargebackState;
set_body(Cash, #chargeback_st{chargeback = Chargeback} = ChargebackState) ->
    ChargebackState#chargeback_st{
        chargeback = Chargeback#domain_InvoicePaymentChargeback{body = Cash}
    }.

-spec set_levy(cash() | undefined, chargeback_state()) ->
    chargeback_state().
set_levy(undefined, ChargebackState) ->
    ChargebackState;
set_levy(Cash, #chargeback_st{chargeback = Chargeback} = ChargebackState) ->
    ChargebackState#chargeback_st{
        chargeback = Chargeback#domain_InvoicePaymentChargeback{levy = Cash}
    }.

-spec set_stage(chargeback_stage() | undefined, chargeback_state()) ->
    chargeback_state().
set_stage(undefined, ChargebackState) ->
    ChargebackState;
set_stage(Stage, #chargeback_st{chargeback = Chargeback} = ChargebackState) ->
    ChargebackState#chargeback_st{
        chargeback = Chargeback#domain_InvoicePaymentChargeback{stage = Stage}
    }.

%%

get_route_provider(#domain_PaymentRoute{provider = ProviderRef}, Revision) ->
    hg_domain:get(Revision, {provider, ProviderRef}).

%%

get_payment_institution(Contract, Revision) ->
    PaymentInstitutionRef = Contract#domain_Contract.payment_institution,
    hg_domain:get(Revision, {payment_institution, PaymentInstitutionRef}).

%%

get_cash_currency(#domain_Cash{currency = Currency}) ->
    Currency.

%%

get_shop_contract_id(#domain_Shop{contract_id = ContractID}) ->
    ContractID.

%%

get_opts_party(#{party := Party}) ->
    Party.

get_opts_party_revision(#{party := Party}) ->
    Party#domain_Party.revision.

get_opts_invoice(#{invoice := Invoice}) ->
    Invoice.

get_opts_invoice_id(Opts) ->
    #domain_Invoice{id = ID} = get_opts_invoice(Opts),
    ID.

%%

get_chargeback_payment_method_selector(#domain_PaymentChargebackServiceTerms{payment_methods = Selector}) ->
    Selector.

%%

get_payment_cost(#domain_InvoicePayment{cost = Cost}) ->
    Cost.

get_payment_id(#domain_InvoicePayment{id = ID}) ->
    ID.

get_payment_tool(#domain_InvoicePayment{payer = Payer}) ->
    get_payer_payment_tool(Payer).

get_payer_payment_tool(?payment_resource_payer(PaymentResource, _ContactInfo)) ->
    get_resource_payment_tool(PaymentResource);
get_payer_payment_tool(?customer_payer(_CustomerID, _, _, PaymentTool, _)) ->
    PaymentTool;
get_payer_payment_tool(?recurrent_payer(PaymentTool, _, _)) ->
    PaymentTool.

get_resource_payment_tool(#domain_DisposablePaymentResource{payment_tool = PaymentTool}) ->
    PaymentTool.

%%

get_invoice_shop_id(#domain_Invoice{shop_id = ShopID}) ->
    ShopID.

get_invoice_created_at(#domain_Invoice{created_at = Dt}) ->
    Dt.

%%

wrap_chargeback_events(ID, Changes) when is_list(Changes) ->
    [?chargeback_ev(ID, Change) || Change <- Changes].

body_change(Body, Body) -> [];
body_change(FinalBody, _Body) -> [?chargeback_body_changed(FinalBody)].

levy_change(Levy, Levy) -> [];
levy_change(FinalLevy, _Levy) -> [?chargeback_levy_changed(FinalLevy)].
