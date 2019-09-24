-module(hg_invoice_payment_chargeback).

-include("domain.hrl").
-include("payment_events.hrl").
-include_lib("damsel/include/dmsl_payment_processing_thrift.hrl").

-export([create/2]).
-export([cancel/2]).
-export([reject/2]).
-export([accept/3]).
-export([reopen/3]).

-export([get/1]).
-export([get_target_status/1]).
-export([get_cash_flow/1]).

-export([set/2]).
-export([set_cash_flow/2]).
-export([set_target_status/2]).

-export_type([st/0]).

-record(chargeback_st, {
    chargeback    :: undefined | chargeback(),
    cash_flow     :: undefined | cash_flow(),
    target_status :: undefined | chargeback_target_status()
}).

-type st()                       :: #chargeback_st{}.
-type chargeback_state()         :: st() | undefined.
-type payment_state()            :: hg_invoice_payment:st().

-type cash_flow()                :: dmsl_domain_thrift:'FinalCashFlow'().
-type chargeback()               :: dmsl_domain_thrift:'InvoicePaymentChargeback'().
-type chargeback_id()            :: dmsl_domain_thrift:'InvoicePaymentChargebackID'().
-type chargeback_target_status() :: dmsl_domain_thrift:'InvoicePaymentChargebackStatus'().
-type chargeback_params()        :: dmsl_payment_processing_thrift:'InvoicePaymentChargebackParams'().
-type accept_params()            :: dmsl_payment_processing_thrift:'InvoicePaymentChargebackAcceptParams'().
-type reopen_params()            :: dmsl_payment_processing_thrift:'InvoicePaymentChargebackAcceptParams'().

-type result() :: {events(), action()}.
-type events() :: [event()].
-type event()  :: dmsl_payment_processing_thrift:'InvoicePaymentChangePayload'().
-type action() :: hg_machine_action:t().

-spec get(chargeback_state()) ->
    chargeback().
get(#chargeback_st{chargeback = Chargeback}) ->
    Chargeback.

-spec get_cash_flow(chargeback_state()) ->
    cash_flow().
get_cash_flow(#chargeback_st{cash_flow = CashFlow}) ->
    CashFlow.

-spec get_target_status(chargeback_state()) ->
    chargeback_target_status().
get_target_status(#chargeback_st{target_status = TargetStatus}) ->
    TargetStatus.

-spec set(chargeback(), chargeback_state()) ->
    chargeback_state().
set(Chargeback, undefined) ->
    #chargeback_st{chargeback = Chargeback};
set(Chargeback, ChargebackState = #chargeback_st{}) ->
    ChargebackState#chargeback_st{chargeback = Chargeback}.

-spec set_target_status(chargeback_target_status(), chargeback_state()) ->
    chargeback_state().
set_target_status(TargetStatus, ChargebackState = #chargeback_st{}) ->
    ChargebackState#chargeback_st{target_status = TargetStatus}.

-spec set_cash_flow(cash_flow(), chargeback_state()) ->
    chargeback_state().
set_cash_flow(CashFlow, ChargebackState = #chargeback_st{}) ->
    ChargebackState#chargeback_st{cash_flow = CashFlow}.

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
    {chargeback(), result()}.

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
    {ok, result()}.

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
    {ok, result()}.

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
    {ok, result()}.

accept(ChargebackID, PaymentState, AcceptParams) ->
    do_accept(ChargebackID, PaymentState, AcceptParams).

%%----------------------------------------------------------------------------
%% @doc
%% `reopen/4` will reopen the chargeback with the given ID, implying that
%% the party that initiated the chargeback was not satisfied by the result
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
    {ok, result()}.

reopen(ChargebackID, PaymentState, ReopenParams) ->
    do_reopen(ChargebackID, PaymentState, ReopenParams).

%% Private

do_create(PaymentState, ChargebackParams) ->
    Chargeback = make_chargeback(PaymentState, ChargebackParams),
    ID         = get_id(Chargeback),
    Action     = hg_machine_action:instant(),
    Change     = ?chargeback_created(Chargeback),
    Events     = [?chargeback_ev(ID, Change)],
    Result     = {Events, Action},
    {Chargeback, Result}.

do_cancel(ID, PaymentState) ->
    ChargebackState = hg_invoice_payment:get_chargeback_state(ID, PaymentState),
    _               = assert_chargeback_pending(ChargebackState),
    Result          = make_cancel_result(ChargebackState, PaymentState),
    {ok, Result}.

do_reject(ID, PaymentState) ->
    ChargebackState = hg_invoice_payment:get_chargeback_state(ID, PaymentState),
    _               = assert_chargeback_pending(ChargebackState),
    Result          = make_reject_result(ChargebackState, PaymentState),
    {ok, Result}.

do_accept(ID, PaymentState, AcceptParams) ->
    ChargebackState = hg_invoice_payment:get_chargeback_state(ID, PaymentState),
    _               = assert_chargeback_pending(ChargebackState),
    Result          = make_accept_result(ChargebackState, PaymentState, AcceptParams),
    {ok, Result}.

do_reopen(ID, PaymentState, ReopenParams) ->
    ChargebackState = hg_invoice_payment:get_chargeback_state(ID, PaymentState),
    _               = assert_chargeback_rejected(ChargebackState),
    Result          = make_reopen_result(ChargebackState, PaymentState, ReopenParams),
    {ok, Result}.

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

make_cancel_result(ChargebackState, PaymentState) ->
    ID           = get_id(ChargebackState),
    Stage        = get_stage(ChargebackState),
    HoldFunds    = get_hold_funds(ChargebackState),
    CashFlowPlan = get_cashflow_plan(ChargebackState),
    Status       = ?chargeback_status_cancelled(),
    case {Stage, HoldFunds} of
        {?chargeback_stage_chargeback(), _HoldFunds} ->
            _      = rollback_cashflow(ChargebackState, CashFlowPlan, PaymentState),
            Action = hg_machine_action:new(),
            Change = ?chargeback_status_changed(Status),
            Events = [?chargeback_ev(ID, Change)],
            {Events, Action};
        {_LaterStage, _HoldFunds = true} ->
            _      = rollback_cashflow(ChargebackState, CashFlowPlan, PaymentState),
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

make_reject_result(ChargebackState, PaymentState) ->
    ID           = get_id(ChargebackState),
    Stage        = get_stage(ChargebackState),
    HoldFunds    = get_hold_funds(ChargebackState),
    CashFlowPlan = get_cashflow_plan(ChargebackState),
    Status       = ?chargeback_status_rejected(),
    case {Stage, HoldFunds} of
        {?chargeback_stage_chargeback(), _HoldFunds = false} ->
            _      = commit_cashflow(ChargebackState, CashFlowPlan, PaymentState),
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
            _      = rollback_cashflow(ChargebackState, CashFlowPlan, PaymentState),
            Action = hg_machine_action:instant(),
            Change = ?chargeback_changed(undefined, undefined, Status),
            Events = [?chargeback_ev(ID, Change)],
            {Events, Action}
    end.

make_accept_result(ChargebackState, PaymentState, AcceptParams) ->
    % Payment        = hg_invoice_payment:get_payment(PaymentState),
    ParamsCash     = get_params_cash(AcceptParams),
    Cash           = define_cash(ParamsCash, ChargebackState),
    _              = assert_cash(Cash, PaymentState),
    ID             = get_id(ChargebackState),
    Stage          = get_stage(ChargebackState),
    HoldFunds      = get_hold_funds(ChargebackState),
    ChargebackCash = get_cash(ChargebackState),
    CashFlowPlan   = get_cashflow_plan(ChargebackState),
    Status         = ?chargeback_status_accepted(),
    case {Stage, Cash, HoldFunds} of
        {_Stage, Cash, _HoldFunds = true}
            when Cash =:= ChargebackCash orelse
                 Cash =:= undefined ->
            _                = commit_cashflow(ChargebackState, CashFlowPlan, PaymentState),
            MaybeChargedBack = maybe_set_charged_back_status(Cash, PaymentState),
            Action           = hg_machine_action:new(),
            Change           = ?chargeback_status_changed(Status),
            Events           = [?chargeback_ev(ID, Change)] ++ MaybeChargedBack,
            {Events, Action};
        {?chargeback_stage_chargeback(), Cash, HoldFunds} ->
            _         = rollback_cashflow(ChargebackState, CashFlowPlan, PaymentState),
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

make_reopen_result(ChargebackState, PaymentState, ReopenParams) ->
    ParamsHoldFunds = get_params_hold_funds(ReopenParams),
    ParamsCash      = get_params_cash(ReopenParams),
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

construct_id(PaymentState) ->
    Chargebacks = hg_invoice_payment:get_chargebacks(PaymentState),
    MaxID       = lists:foldl(fun find_max_id/2, 0, Chargebacks),
    genlib:to_binary(MaxID + 1).

find_max_id(#domain_InvoicePaymentChargeback{id = ID}, Max) ->
    IntID = genlib:to_int(ID),
    erlang:max(IntID, Max).

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

% prepare_cashflow(ChargebackState, CashFlowPlan, PaymentState) ->
%     PlanID = construct_chargeback_plan_id(ChargebackState, PaymentState),
%     hg_accounting:plan(PlanID, CashFlowPlan).

commit_cashflow(ChargebackState, CashFlowPlan, PaymentState) ->
    PlanID = construct_chargeback_plan_id(ChargebackState, PaymentState),
    hg_accounting:commit(PlanID, [CashFlowPlan]).

rollback_cashflow(ChargebackState, CashFlowPlan, PaymentState) ->
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

maybe_set_charged_back_status(Cash, PaymentState) ->
    case get_remaining_payment_amount(Cash, PaymentState) of
        ?cash(Amount, _) when Amount =:= 0 ->
            [?payment_status_changed(?charged_back())];
        ?cash(Amount, _) when Amount > 0 ->
            []
    end.

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
    ct:print("InterimPaymentAmount\n~p\nCash\n~p", [InterimPaymentAmount, Cash]),
    hg_cash:sub(InterimPaymentAmount, Cash).

assert_remaining_payment_amount(?cash(Amount, _), _PaymentState) when Amount >= 0 ->
    ok;
assert_remaining_payment_amount(?cash(Amount, _), PaymentState) when Amount < 0 ->
    Maximum = hg_invoice_payment:get_remaining_payment_balance(PaymentState),
    throw(#payproc_InvoicePaymentAmountExceeded{maximum = Maximum}).

get_opts_party_revision(#{party := Party}) ->
    Party#domain_Party.revision.

get_opts_invoice(#{invoice := Invoice}) ->
    Invoice.

get_opts_invoice_id(Opts) ->
    #domain_Invoice{id = ID} = get_opts_invoice(Opts),
    ID.

get_payment_id(#domain_InvoicePayment{id = ID}) ->
    ID.

%% Params Accessors

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

% set_status(Status, Chargeback = #domain_InvoicePaymentChargeback{}) ->
%     Chargeback#domain_InvoicePaymentChargeback{status = Status}.

% set_stage(undefined, Chargeback) ->
%     Chargeback;
% set_stage(Stage, Chargeback) ->
%     Chargeback#domain_InvoicePaymentChargeback{stage = Stage}.

% set_cash(undefined, Chargeback = #domain_InvoicePaymentChargeback{}) ->
%     Chargeback;
% set_cash(Cash, Chargeback = #domain_InvoicePaymentChargeback{}) ->
%     Chargeback#domain_InvoicePaymentChargeback{cash = Cash}.

% set_hold_funds(undefined, Chargeback = #domain_InvoicePaymentChargeback{}) ->
%     Chargeback;
% set_hold_funds(HoldFunds, Chargeback = #domain_InvoicePaymentChargeback{}) ->
%     Chargeback#domain_InvoicePaymentChargeback{hold_funds = HoldFunds}.

%% Getters

get_id(#chargeback_st{chargeback = Chargeback}) ->
    get_id(Chargeback);
get_id(#domain_InvoicePaymentChargeback{id = ID}) ->
    ID.

get_cash(#chargeback_st{chargeback = Chargeback}) ->
    get_cash(Chargeback);
get_cash(#domain_InvoicePaymentChargeback{cash = Cash}) ->
    Cash.

get_cashflow_plan(#chargeback_st{cash_flow = CashFlow}) ->
    {1, CashFlow}.

% get_revision(#chargeback_st{chargeback = Chargeback}) ->
%     get_revision(Chargeback);
% get_revision(#domain_InvoicePaymentChargeback{domain_revision = Revision}) ->
%     Revision.

% get_status(#domain_InvoicePaymentChargeback{status = Status}) ->
%     Status.

get_hold_funds(#chargeback_st{chargeback = Chargeback}) ->
    get_hold_funds(Chargeback);
get_hold_funds(#domain_InvoicePaymentChargeback{hold_funds = HoldFunds}) ->
    HoldFunds.

get_stage(#chargeback_st{chargeback = Chargeback}) ->
    get_stage(Chargeback);
get_stage(#domain_InvoicePaymentChargeback{stage = Stage}) ->
    Stage.

get_next_stage(#chargeback_st{chargeback = Chargeback}) ->
    get_next_stage(Chargeback);
get_next_stage(#domain_InvoicePaymentChargeback{stage = ?chargeback_stage_chargeback()}) ->
    ?chargeback_stage_pre_arbitration();
get_next_stage(#domain_InvoicePaymentChargeback{stage = ?chargeback_stage_pre_arbitration()}) ->
    ?chargeback_stage_arbitration().
