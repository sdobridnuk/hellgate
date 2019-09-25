-module(hg_invoice_payment_chargeback).

-include("domain.hrl").
-include("payment_events.hrl").
-include_lib("damsel/include/dmsl_payment_processing_thrift.hrl").

-export([create/2]).
-export([cancel/2]).
-export([reject/2]).
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

-type chargeback_target_status() :: dmsl_domain_thrift:'InvoicePaymentChargebackStatus'().

-type chargeback_params()        :: dmsl_payment_processing_thrift:'InvoicePaymentChargebackParams'().
-type accept_params()            :: dmsl_payment_processing_thrift:'InvoicePaymentChargebackAcceptParams'().
-type reopen_params()            :: dmsl_payment_processing_thrift:'InvoicePaymentChargebackReopenParams'().

-type chargeback_change()        :: dmsl_payment_processing_thrift:'InvoicePaymentChargebackChangePayload'().

-type result()                   :: {events(), action()}.
-type events()                   :: [event()].
-type event()                    :: dmsl_payment_processing_thrift:'InvoicePaymentChangePayload'().
-type action()                   :: hg_machine_action:t().
-type machine_result()           :: hg_invoice_payment:machine_result().

-type setter()                   :: fun((any(), chargeback_state()) -> chargeback_state()).

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
%%    `hold_funds`: whether or not we want to deduct the cost of the
%%    chargeback from the merchant's account right away, set to `false` by
%%    default. Can be set to `true` for chargebacks that seem to have a
%%    higher amount of risk.
%%
%%    `cash`: set the amount of cash that is to be deducted. Will default to
%%    full amount if undefined.
%% @end
%%----------------------------------------------------------------------------
-spec create(payment_state(), chargeback_params()) ->
    {chargeback(), result()} | no_return().
create(PaymentState, ChargebackParams) ->
    do_create(PaymentState, ChargebackParams).

%%----------------------------------------------------------------------------
%% @doc
%% `cancel/3` will cancel the chargeback with the given ID. All funds
%% including the fee will be trasferred back to the merchant as a result
%% of this operation.
%% @end
%%----------------------------------------------------------------------------
-spec cancel(chargeback_id(), payment_state()) ->
    {ok, result()} | no_return().
cancel(ChargebackID, PaymentState) ->
    do_cancel(ChargebackID, PaymentState).

%%----------------------------------------------------------------------------
%% @doc
%% `reject/3` will reject the chargeback with the given ID, implying that no
%% sufficient evidence has been found to support the chargeback claim. The
%% merchant will still have to pay the fee, if any.
%% @end
%%----------------------------------------------------------------------------
-spec reject(chargeback_id(), payment_state()) ->
    {ok, result()} | no_return().
reject(ChargebackID, PaymentState) ->
    do_reject(ChargebackID, PaymentState).

%%----------------------------------------------------------------------------
%% @doc
%% `accept/4` will accept the chargeback with the given ID, implying that
%% sufficient evidence has been found to support the chargeback claim. The
%% cost of the chargeback will be deducted from the merchant's account.
%%
%% `accept/4` can have `cash` as an extra parameter for situations when
%% the final sum of the chargeback should be different from the initial
%% amount. Will default to the current amount if not set.
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
%% Parameters:
%%    `hold_funds`: whether or not we want to deduct the cost of the
%%    chargeback from the merchant's account right away. Can be set to
%%    `true` for chargebacks that seem to have a higher amount of risk.
%%    Will default to the current value of this parameter if not set.
%%
%%    `cash`: set the amount of cash that is to be deducted. Will default to
%%    full the current amount if undefined.
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
    do_create_cash_flow(ChargebackID, PaymentState).

-spec update_cash_flow(chargeback_id(), action(), payment_state()) ->
    machine_result() | no_return().
update_cash_flow(ChargebackID, _Action, PaymentState) ->
    do_update_cash_flow(ChargebackID, PaymentState).

-spec finalise(chargeback_id(), action(), payment_state()) ->
    machine_result() | no_return().
finalise(ChargebackID, Action, PaymentState) ->
    do_finalise(ChargebackID, Action, PaymentState).

%% Private

-spec do_create(payment_state(), chargeback_params()) ->
    {chargeback(), result()} | no_return().
do_create(PaymentState, ChargebackParams) ->
    Chargeback = make_chargeback(PaymentState, ChargebackParams),
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
    _               = assert_chargeback_pending(ChargebackState),
    Result          = make_cancel_result(ChargebackState, PaymentState),
    {ok, Result}.

-spec do_reject(chargeback_id(), payment_state()) ->
    {ok, result()} | no_return().
do_reject(ID, PaymentState) ->
    ChargebackState = hg_invoice_payment:get_chargeback_state(ID, PaymentState),
    _               = assert_chargeback_pending(ChargebackState),
    Result          = make_reject_result(ChargebackState, PaymentState),
    {ok, Result}.

-spec do_accept(chargeback_id(), payment_state(), accept_params()) ->
    {ok, result()} | no_return().
do_accept(ID, PaymentState, AcceptParams) ->
    ChargebackState = hg_invoice_payment:get_chargeback_state(ID, PaymentState),
    _               = assert_chargeback_pending(ChargebackState),
    Result          = make_accept_result(ChargebackState, PaymentState, AcceptParams),
    {ok, Result}.

-spec do_reopen(chargeback_id(), payment_state(), reopen_params()) ->
    {ok, result()} | no_return().
do_reopen(ID, PaymentState, ReopenParams) ->
    ChargebackState = hg_invoice_payment:get_chargeback_state(ID, PaymentState),
    _               = assert_chargeback_rejected(ChargebackState),
    Result          = make_reopen_result(ChargebackState, PaymentState, ReopenParams),
    {ok, Result}.

-spec do_merge_change(chargeback_change(), chargeback_state()) ->
    chargeback_state().
do_merge_change(?chargeback_created(Chargeback), ChargebackState) ->
    set(Chargeback, ChargebackState);
do_merge_change(?chargeback_changed(Cash, HoldFunds, TargetStatus, Stage), ChargebackState) ->
    Changes = [
        {fun set_cash/2         , Cash},
        {fun set_hold_funds/2   , HoldFunds},
        {fun set_target_status/2, TargetStatus},
        {fun set_stage/2        , Stage}
    ],
    merge_state_changes(Changes, ChargebackState);
do_merge_change(?chargeback_status_changed(Status), ChargebackState) ->
    Changes = [
        {fun set_status/2       , Status},
        {fun set_target_status/2, undefined}
    ],
    merge_state_changes(Changes, ChargebackState);
do_merge_change(?chargeback_cash_flow_created(CashFlow), ChargebackState) ->
    set_cash_flow(CashFlow, ChargebackState);
do_merge_change(?chargeback_cash_flow_changed(CashFlow), ChargebackState) ->
    set_cash_flow(CashFlow, ChargebackState).

-spec merge_state_changes([{setter(), any()}], chargeback_state()) ->
    chargeback_state().
merge_state_changes(Changes, ChargebackState) ->
    lists:foldl(fun({Fun, Arg}, Acc) -> Fun(Arg, Acc) end, ChargebackState, Changes).

-spec do_create_cash_flow(chargeback_id(), payment_state()) ->
    machine_result() | no_return().
do_create_cash_flow(ID, PaymentState) ->
    FinalCashFlow   = make_chargeback_cash_flow(ID, PaymentState),
    ChargebackState = hg_invoice_payment:get_chargeback_state(ID, PaymentState),
    CashFlowPlan    = {1, FinalCashFlow},
    _               = prepare_cash_flow(ChargebackState, CashFlowPlan, PaymentState),
    CFEvent         = ?chargeback_cash_flow_created(FinalCashFlow),
    CBEvent         = ?chargeback_ev(ID, CFEvent),
    Action0         = hg_machine_action:new(),
    {done, {[CBEvent], Action0}}.

-spec do_update_cash_flow(chargeback_id(), payment_state()) ->
    machine_result() | no_return().
do_update_cash_flow(ID, PaymentState) ->
    FinalCashFlow   = make_chargeback_cash_flow(ID, PaymentState),
    ChargebackState = hg_invoice_payment:get_chargeback_state(ID, PaymentState),
    TargetStatus    = get_target_status(ChargebackState),
    case {FinalCashFlow, TargetStatus} of
        {[], _TargetStatus} ->
            CFEvent = ?chargeback_cash_flow_changed([]),
            CBEvent = ?chargeback_ev(ID, CFEvent),
            Action  = hg_machine_action:instant(),
            {done, {[CBEvent], Action}};
        {FinalCashFlow, ?chargeback_status_cancelled()} ->
            RevertedCF   = hg_cashflow:revert(FinalCashFlow),
            CashFlowPlan = {1, RevertedCF},
            _            = prepare_cash_flow(ChargebackState, CashFlowPlan, PaymentState),
            CFEvent      = ?chargeback_cash_flow_changed(RevertedCF),
            CBEvent      = ?chargeback_ev(ID, CFEvent),
            Action       = hg_machine_action:instant(),
            {done, {[CBEvent], Action}};
        _ ->
            CashFlowPlan = {1, FinalCashFlow},
            _            = prepare_cash_flow(ChargebackState, CashFlowPlan, PaymentState),
            CFEvent      = ?chargeback_cash_flow_changed(FinalCashFlow),
            CBEvent      = ?chargeback_ev(ID, CFEvent),
            Action       = hg_machine_action:instant(),
            {done, {[CBEvent], Action}}
    end.

-spec do_finalise(chargeback_id(), action(), payment_state()) ->
    machine_result() | no_return().
do_finalise(ID, Action, PaymentState) ->
    ChargebackState = hg_invoice_payment:get_chargeback_state(ID, PaymentState),
    TargetStatus    = get_target_status(ChargebackState),
    CashFlowPlan    = get_cash_flow_plan(ChargebackState),
    case {TargetStatus, CashFlowPlan} of
        {?chargeback_status_pending(), _CashFlowPlan} ->
            StatusEvent = ?chargeback_status_changed(TargetStatus),
            CBEvent     = ?chargeback_ev(ID, StatusEvent),
            {done, {[CBEvent], Action}};
        {_NotPending, {1, []}} ->
            StatusEvent      = ?chargeback_status_changed(TargetStatus),
            CBEvent          = ?chargeback_ev(ID, StatusEvent),
            ChargebackCash   = get_cash(ChargebackState),
            MaybeChargedBack = maybe_set_charged_back_status(TargetStatus, ChargebackCash, PaymentState),
            {done, {[CBEvent] ++ MaybeChargedBack, Action}};
        {_NotPending, CashFlowPlan} ->
            _                = commit_cash_flow(ChargebackState, CashFlowPlan, PaymentState),
            StatusEvent      = ?chargeback_status_changed(TargetStatus),
            CBEvent          = ?chargeback_ev(ID, StatusEvent),
            ChargebackCash   = get_cash(ChargebackState),
            MaybeChargedBack = maybe_set_charged_back_status(TargetStatus, ChargebackCash, PaymentState),
            {done, {[CBEvent] ++ MaybeChargedBack, Action}}
    end.

-spec make_chargeback(payment_state(), chargeback_params()) ->
    chargeback() | no_return().
make_chargeback(PaymentState, ChargebackParams) ->
    Revision      = hg_domain:head(),
    Payment       = hg_invoice_payment:get_payment(PaymentState),
    PaymentOpts   = hg_invoice_payment:get_opts(PaymentState),
    PartyRevision = get_opts_party_revision(PaymentOpts),
    _             = assert_no_pending_chargebacks(PaymentState),
    _             = assert_payment_status(captured, Payment),
    HoldFunds     = get_params_hold_funds(ChargebackParams),
    ParamsCash    = get_params_cash(ChargebackParams),
    ReasonCode    = get_params_reason_code(ChargebackParams),
    Cash          = define_cash(ParamsCash, Payment),
    _             = assert_cash(Cash, PaymentState),
    #domain_InvoicePaymentChargeback{
        id              = construct_id(PaymentState),
        created_at      = hg_datetime:format_now(),
        stage           = ?chargeback_stage_chargeback(),
        status          = ?chargeback_status_pending(),
        domain_revision = Revision,
        party_revision  = PartyRevision,
        reason_code     = ReasonCode,
        hold_funds      = HoldFunds,
        cash            = Cash
    }.

-spec make_cancel_result(chargeback_state(), payment_state()) ->
    result() | no_return().
make_cancel_result(ChargebackState, PaymentState) ->
    ID           = get_id(ChargebackState),
    Stage        = get_stage(ChargebackState),
    HoldFunds    = get_hold_funds(ChargebackState),
    CashFlowPlan = get_cash_flow_plan(ChargebackState),
    Status       = ?chargeback_status_cancelled(),
    case {Stage, HoldFunds} of
        {?chargeback_stage_chargeback(), _HoldFunds} ->
            _      = rollback_cash_flow(ChargebackState, CashFlowPlan, PaymentState),
            Action = hg_machine_action:new(),
            Change = ?chargeback_status_changed(Status),
            Events = [?chargeback_ev(ID, Change)],
            {Events, Action};
        {_LaterStage, _HoldFunds = true} ->
            _      = rollback_cash_flow(ChargebackState, CashFlowPlan, PaymentState),
            Action = hg_machine_action:instant(),
            Change = ?chargeback_changed(undefined, undefined, Status),
            Events = [?chargeback_ev(ID, Change)],
            {Events, Action};
        {_LaterStage, _HoldFunds = false} ->
            Action = hg_machine_action:instant(),
            Change = ?chargeback_changed(undefined, undefined, Status),
            Events = [?chargeback_ev(ID, Change)],
            {Events, Action}
    end.

-spec make_reject_result(chargeback_state(), payment_state()) ->
    result() | no_return().
make_reject_result(ChargebackState, PaymentState) ->
    ID           = get_id(ChargebackState),
    Stage        = get_stage(ChargebackState),
    HoldFunds    = get_hold_funds(ChargebackState),
    CashFlowPlan = get_cash_flow_plan(ChargebackState),
    Status       = ?chargeback_status_rejected(),
    case {Stage, HoldFunds} of
        {?chargeback_stage_chargeback(), _HoldFunds = false} ->
            _      = commit_cash_flow(ChargebackState, CashFlowPlan, PaymentState),
            Action = hg_machine_action:new(),
            Change = ?chargeback_status_changed(Status),
            Events = [?chargeback_ev(ID, Change)],
            {Events, Action};
        {_LaterStage, _HoldFunds = false} ->
            Action = hg_machine_action:new(),
            Change = ?chargeback_status_changed(Status),
            Events = [?chargeback_ev(ID, Change)],
            {Events, Action};
        {_LaterStage, _HoldFunds = true} ->
            _      = rollback_cash_flow(ChargebackState, CashFlowPlan, PaymentState),
            Action = hg_machine_action:instant(),
            Change = ?chargeback_changed(undefined, undefined, Status),
            Events = [?chargeback_ev(ID, Change)],
            {Events, Action}
    end.

-spec make_accept_result(chargeback_state(), payment_state(), accept_params()) ->
    result() | no_return().
make_accept_result(ChargebackState, PaymentState, AcceptParams) ->
    ParamsCash     = get_params_cash(AcceptParams),
    %% REWORK DEFINE CASH
    Cash           = define_cash(ParamsCash, ChargebackState),
    _              = assert_cash(Cash, PaymentState),
    ID             = get_id(ChargebackState),
    Stage          = get_stage(ChargebackState),
    HoldFunds      = get_hold_funds(ChargebackState),
    ChargebackCash = get_cash(ChargebackState),
    CashFlowPlan   = get_cash_flow_plan(ChargebackState),
    Status         = ?chargeback_status_accepted(),
    case {Stage, Cash, HoldFunds} of
        {_Stage, ChargebackCash, _HoldFunds = true} ->
            _                = commit_cash_flow(ChargebackState, CashFlowPlan, PaymentState),
            MaybeChargedBack = maybe_set_charged_back_status(Status, Cash, PaymentState),
            Action           = hg_machine_action:new(),
            Change           = ?chargeback_status_changed(Status),
            Events           = [?chargeback_ev(ID, Change)] ++ MaybeChargedBack,
            {Events, Action};
        {?chargeback_stage_chargeback(), Cash, HoldFunds} ->
            _         = rollback_cash_flow(ChargebackState, CashFlowPlan, PaymentState),
            Action    = hg_machine_action:instant(),
            Change    = ?chargeback_changed(Cash, HoldFunds, Status),
            Events    = [?chargeback_ev(ID, Change)],
            {Events, Action};
        {_LaterStage, Cash, HoldFunds} ->
            Action    = hg_machine_action:instant(),
            Change    = ?chargeback_changed(Cash, HoldFunds, Status),
            Events    = [?chargeback_ev(ID, Change)],
            {Events, Action}
    end.

-spec make_reopen_result(chargeback_state(), payment_state(), reopen_params()) ->
    result() | no_return().
make_reopen_result(ChargebackState, PaymentState, ReopenParams) ->
    ParamsHoldFunds = get_params_hold_funds(ReopenParams),
    ParamsCash      = get_params_cash(ReopenParams),
    %% REWORK DEFINE CASH
    Cash            = define_cash(ParamsCash, ChargebackState),
    _               = assert_cash(Cash, PaymentState),
    _               = assert_not_arbitration(ChargebackState),
    ID              = get_id(ChargebackState),
    Stage           = get_next_stage(ChargebackState),
    Action          = hg_machine_action:instant(),
    Status          = ?chargeback_status_pending(),
    Change          = ?chargeback_changed(Cash, ParamsHoldFunds, Status, Stage),
    Events          = [?chargeback_ev(ID, Change)],
    {Events, Action}.

-spec make_chargeback_cash_flow(chargeback_id(), payment_state()) ->
    cash_flow() | no_return().
make_chargeback_cash_flow(ID, PaymentState) ->
    ChargebackState = hg_invoice_payment:get_chargeback_state(ID, PaymentState),
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
    _               = assert_contract_active(Contract),
    TermSet         = hg_party:get_terms(Contract, CreatedAt, Revision),
    MerchantTerms   = get_merchant_chargeback_terms(TermSet),
    VS0             = collect_validation_varset(Party, Shop, Payment, ChargebackState),
    VS1             = validate_chargeback(MerchantTerms, Payment, VS0, Revision),
    Route           = hg_invoice_payment:get_route(PaymentState),
    PaymentsTerms   = hg_routing:get_payments_terms(Route, Revision),
    ProviderTerms   = get_provider_chargeback_terms(PaymentsTerms, Payment),
    CashFlow        = collect_chargeback_cash_flow(MerchantTerms, ProviderTerms, ChargebackState, VS1, Revision),
    PmntInstitution = get_payment_institution(Contract, Revision),
    Provider        = get_route_provider(Route, Revision),
    AccountMap      = collect_account_map(Payment, Shop, PmntInstitution, Provider, VS1, Revision),
    Context         = build_cash_flow_context(ChargebackState),
    hg_cashflow:finalize(CashFlow, Context, AccountMap).

collect_chargeback_cash_flow(MerchantTerms, ProviderTerms, ChargebackState, VS, Revision) ->
    TargetStatus = get_target_status(ChargebackState),
    HoldFunds    = get_hold_funds(ChargebackState),
    Stage        = get_stage(ChargebackState),
    #domain_PaymentChargebackServiceTerms{fees        = MerchantCashflowSelector} = MerchantTerms,
    #domain_PaymentChargebackProvisionTerms{cash_flow = ProviderCashflowSelector} = ProviderTerms,
    ProviderCashflow =
        case {TargetStatus, HoldFunds} of
            {TargetStatus, HoldFunds}
                when TargetStatus =:= ?chargeback_status_accepted();
                     TargetStatus =/= ?chargeback_status_rejected(), HoldFunds =:= true ->
                reduce_selector(provider_chargeback_cash_flow, ProviderCashflowSelector, VS, Revision);
            _ ->
                []
        end,
    MerchantCashflow =
        case {TargetStatus, Stage} of
            {TargetStatus, Stage}
                when Stage        =:= ?chargeback_stage_chargeback();
                     TargetStatus =:= ?chargeback_status_cancelled() ->
                reduce_selector(merchant_chargeback_fees, MerchantCashflowSelector, VS, Revision);
            _Other ->
                []
        end,
    MerchantCashflow ++ ProviderCashflow.

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
    #{operation_amount => get_cash(ChargebackState)}.

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

define_cash(undefined, #chargeback_st{chargeback = Chargeback}) ->
    get_cash(Chargeback);
define_cash(?cash(_Amount, _SymCode) = Cash, #chargeback_st{chargeback = Chargeback}) ->
    define_cash(Cash, Chargeback);
define_cash(undefined, #domain_InvoicePayment{cost = Cost}) ->
    Cost;
define_cash(?cash(_, SymCode) = Cash, #domain_InvoicePayment{cost = ?cash(_, SymCode)}) ->
    Cash;
define_cash(?cash(_, SymCode) = Cash, #domain_InvoicePaymentChargeback{cash = ?cash(_, SymCode)}) ->
    Cash;
define_cash(?cash(_, SymCode), _PaymentOrChargeback) ->
    throw(#payproc_InconsistentChargebackCurrency{currency = SymCode}).

prepare_cash_flow(ChargebackState, CashFlowPlan, PaymentState) ->
    PlanID = construct_chargeback_plan_id(ChargebackState, PaymentState),
    hg_accounting:plan(PlanID, CashFlowPlan).

commit_cash_flow(ChargebackState, CashFlowPlan, PaymentState) ->
    PlanID = construct_chargeback_plan_id(ChargebackState, PaymentState),
    hg_accounting:commit(PlanID, [CashFlowPlan]).

rollback_cash_flow(ChargebackState, CashFlowPlan, PaymentState) ->
    PlanID = construct_chargeback_plan_id(ChargebackState, PaymentState),
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

maybe_set_charged_back_status(?chargeback_status_accepted(), Cash, PaymentState) ->
    case get_remaining_payment_amount(Cash, PaymentState) of
        ?cash(Amount, _) when Amount =:= 0 ->
            [?payment_status_changed(?charged_back())];
        ?cash(Amount, _) when Amount > 0 ->
            []
    end;
maybe_set_charged_back_status(_NotAccepted, _Cash, _PaymentState) ->
    [].

collect_validation_varset(Party, Shop, Payment, ChargebackState) ->
    #domain_Party{id = PartyID} = Party,
    #domain_Shop{
        id = ShopID,
        category = Category,
        account = #domain_ShopAccount{currency = Currency}
    } = Shop,
    #{
        party_id     => PartyID,
        shop_id      => ShopID,
        category     => Category,
        currency     => Currency,
        cost         => get_cash(ChargebackState),
        payment_tool => get_payment_tool(Payment)
    }.

%% Asserts

assert_not_arbitration(#chargeback_st{chargeback = Chargeback}) ->
    assert_not_arbitration(Chargeback);
assert_not_arbitration(#domain_InvoicePaymentChargeback{stage = ?chargeback_stage_arbitration()}) ->
    throw(#payproc_InvoicePaymentChargebackCannotReopenAfterArbitration{});
assert_not_arbitration(#domain_InvoicePaymentChargeback{}) ->
    ok.

assert_chargeback_rejected(#chargeback_st{chargeback = Chargeback}) ->
    assert_chargeback_rejected(Chargeback);
assert_chargeback_rejected(#domain_InvoicePaymentChargeback{status = ?chargeback_status_rejected()}) ->
    ok;
assert_chargeback_rejected(#domain_InvoicePaymentChargeback{status = Status}) ->
    throw(#payproc_InvoicePaymentChargebackInvalidStatus{status = Status}).

assert_chargeback_pending(#chargeback_st{chargeback = Chargeback}) ->
    assert_chargeback_pending(Chargeback);
assert_chargeback_pending(#domain_InvoicePaymentChargeback{status = ?chargeback_status_pending()}) ->
    ok;
assert_chargeback_pending(#domain_InvoicePaymentChargeback{status = Status}) ->
    throw(#payproc_InvoicePaymentChargebackInvalidStatus{status = Status}).

assert_no_pending_chargebacks(PaymentState) ->
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

assert_payment_status(Status, #domain_InvoicePayment{status = {Status, _}}) ->
    ok;
assert_payment_status(_, #domain_InvoicePayment{status = Status}) ->
    throw(#payproc_InvalidPaymentStatus{status = Status}).

assert_cash(undefined, _PaymentState) ->
    ok;
assert_cash(Cash, PaymentState) ->
    PaymentAmount = get_remaining_payment_amount(Cash, PaymentState),
    assert_remaining_payment_amount(PaymentAmount, PaymentState).

get_remaining_payment_amount(Cash, PaymentState) ->
    InterimPaymentAmount = hg_invoice_payment:get_remaining_payment_balance(PaymentState),
    hg_cash:sub(InterimPaymentAmount, Cash).

assert_remaining_payment_amount(?cash(Amount, _), _PaymentState) when Amount >= 0 ->
    ok;
assert_remaining_payment_amount(?cash(Amount, _), PaymentState) when Amount < 0 ->
    Maximum = hg_invoice_payment:get_remaining_payment_balance(PaymentState),
    throw(#payproc_InvoicePaymentAmountExceeded{maximum = Maximum}).

get_merchant_chargeback_terms(#domain_TermSet{payments = PaymentsTerms}) ->
    get_merchant_chargeback_terms(PaymentsTerms);
get_merchant_chargeback_terms(#domain_PaymentsServiceTerms{chargebacks = Terms}) when Terms /= undefined ->
    Terms;
get_merchant_chargeback_terms(#domain_PaymentsServiceTerms{chargebacks = undefined}) ->
    throw(#payproc_OperationNotPermitted{}).

assert_contract_active(#domain_Contract{status = {active, _}}) ->
    ok;
assert_contract_active(#domain_Contract{status = Status}) ->
    throw(#payproc_InvalidContractStatus{status = Status}).

%% Getters

-spec get_id(chargeback_state()) ->
    chargeback_id().
get_id(#chargeback_st{chargeback = Chargeback}) ->
    get_id(Chargeback);
get_id(#domain_InvoicePaymentChargeback{id = ID}) ->
    ID.

-spec get_target_status(chargeback_state()) ->
    chargeback_target_status().
get_target_status(#chargeback_st{target_status = TargetStatus}) ->
    TargetStatus.

-spec get_cash(chargeback_state()) ->
    cash().
get_cash(#chargeback_st{chargeback = Chargeback}) ->
    get_cash(Chargeback);
get_cash(#domain_InvoicePaymentChargeback{cash = Cash}) ->
    Cash.

-spec get_cash_flow_plan(chargeback_state()) ->
    hg_accounting:batch().
get_cash_flow_plan(#chargeback_st{cash_flow = CashFlow}) ->
    {1, CashFlow}.

-spec get_revision(chargeback_state()) ->
    hg_domain:revision().
get_revision(#chargeback_st{chargeback = Chargeback}) ->
    get_revision(Chargeback);
get_revision(#domain_InvoicePaymentChargeback{domain_revision = Revision}) ->
    Revision.

-spec get_hold_funds(chargeback_state()) ->
    boolean().
get_hold_funds(#chargeback_st{chargeback = Chargeback}) ->
    get_hold_funds(Chargeback);
get_hold_funds(#domain_InvoicePaymentChargeback{hold_funds = HoldFunds}) ->
    HoldFunds.

-spec get_stage(chargeback_state()) ->
    chargeback_stage().
get_stage(#chargeback_st{chargeback = Chargeback}) ->
    get_stage(Chargeback);
get_stage(#domain_InvoicePaymentChargeback{stage = Stage}) ->
    Stage.

-spec get_next_stage(chargeback_state()) ->
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

-spec set_cash(cash() | undefined, chargeback_state()) ->
    chargeback_state().
set_cash(undefined, ChargebackState) ->
    ChargebackState;
set_cash(Cash, #chargeback_st{chargeback = Chargeback} = ChargebackState) ->
    ChargebackState#chargeback_st{
        chargeback = Chargeback#domain_InvoicePaymentChargeback{cash = Cash}
    }.

-spec set_hold_funds(boolean() | undefined, chargeback_state()) ->
    chargeback_state().
set_hold_funds(undefined, ChargebackState) ->
    ChargebackState;
set_hold_funds(HoldFunds, #chargeback_st{chargeback = Chargeback} = ChargebackState) ->
    ChargebackState#chargeback_st{
        chargeback = Chargeback#domain_InvoicePaymentChargeback{hold_funds = HoldFunds}
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

get_params_hold_funds(#payproc_InvoicePaymentChargebackReopenParams{hold_funds = HoldFunds}) ->
    HoldFunds;
get_params_hold_funds(#payproc_InvoicePaymentChargebackParams{hold_funds = HoldFunds}) ->
    HoldFunds.

get_params_cash(#payproc_InvoicePaymentChargebackReopenParams{cash = Cash}) ->
    Cash;
get_params_cash(#payproc_InvoicePaymentChargebackAcceptParams{cash = Cash}) ->
    Cash;
get_params_cash(#payproc_InvoicePaymentChargebackParams{cash = Cash}) ->
    Cash.

get_params_reason_code(#payproc_InvoicePaymentChargebackParams{reason_code = ReasonCode}) ->
    ReasonCode.
