-module(hg_invoice_payment_chargeback).

-include("domain.hrl").
-include("payment_events.hrl").
-include_lib("damsel/include/dmsl_payment_processing_thrift.hrl").

-export(
    [ create/2
    , cancel/1
    , reject/3
    , accept/3
    , reopen/3
    ]).

-export(
    [ merge_change/2
    , process_timeout/4
    ]).

-export(
    [ get/1
    , get_body/1
    , get_status/1
    , get_target_status/1
    , is_pending/1
    ]).

-export_type(
    [ id/0
    , opts/0
    , state/0
    , activity/0
    ]).

-export_type(
    [ create_params/0
    , accept_params/0
    , reject_params/0
    , reopen_params/0
    ]).

-record( chargeback_st
       , { chargeback    :: undefined | chargeback()
         , target_status :: undefined | status()
         , state = init  :: init | active
         , cash_flow_plans =
               #{ ?chargeback_stage_chargeback()      => []
                , ?chargeback_stage_pre_arbitration() => []
                , ?chargeback_stage_arbitration()     => []
                } :: cash_flow_plans()
         }
       ).

-type state()
    :: #chargeback_st{}.

-type cash_flow_plans()
    :: #{ ?chargeback_stage_chargeback()      := [batch()]
        , ?chargeback_stage_pre_arbitration() := [batch()]
        , ?chargeback_stage_arbitration()     := [batch()]
        }.

-type opts()
    :: #{ payment_state := payment_state()
        , party         := party()
        , invoice       := invoice()
        }.

-type payment_state()
    :: hg_invoice_payment:st().

-type party()
    :: dmsl_domain_thrift:'Party'().
-type invoice()
    :: dmsl_domain_thrift:'Invoice'().

-type chargeback()
    :: dmsl_domain_thrift:'InvoicePaymentChargeback'().

-type id()
    :: dmsl_domain_thrift:'InvoicePaymentChargebackID'().
-type status()
    :: dmsl_domain_thrift:'InvoicePaymentChargebackStatus'().
-type stage()
    :: dmsl_domain_thrift:'InvoicePaymentChargebackStage'().

-type cash()
    :: dmsl_domain_thrift:'Cash'().
-type cash_flow()
    :: dmsl_domain_thrift:'FinalCashFlow'().
-type batch()
    :: hg_accounting:batch().

-type create_params()
    :: dmsl_payment_processing_thrift:'InvoicePaymentChargebackParams'().
-type accept_params()
    :: dmsl_payment_processing_thrift:'InvoicePaymentChargebackAcceptParams'().
-type reject_params()
    :: dmsl_payment_processing_thrift:'InvoicePaymentChargebackRejectParams'().
-type reopen_params()
    :: dmsl_payment_processing_thrift:'InvoicePaymentChargebackReopenParams'().

-type result()
    :: {[change()], action()}.
-type change()
    :: dmsl_payment_processing_thrift:'InvoicePaymentChargebackChangePayload'().

-type action()
    :: hg_machine_action:t().

-type activity()
    :: preparing_initial_cash_flow
     | updating_chargeback
     | updating_cash_flow
     | finalising_accounter
     .

-spec get(state()) ->
    chargeback().
get(#chargeback_st{chargeback = Chargeback}) ->
    Chargeback.

-spec get_body(state() | chargeback()) ->
    cash().
get_body(#chargeback_st{chargeback = Chargeback}) ->
    get_body(Chargeback);
get_body(#domain_InvoicePaymentChargeback{body = Body}) ->
    Body.

-spec get_status(state() | chargeback()) ->
    status().
get_status(#chargeback_st{chargeback = Chargeback}) ->
    get_status(Chargeback);
get_status(#domain_InvoicePaymentChargeback{status = Status}) ->
    Status.

-spec get_target_status(state()) ->
    status() | undefined.
get_target_status(#chargeback_st{target_status = TargetStatus}) ->
    TargetStatus.

-spec is_pending(chargeback() | state()) ->
    boolean().
is_pending(#chargeback_st{chargeback = Chargeback}) ->
    is_pending(Chargeback);
is_pending(#domain_InvoicePaymentChargeback{status = ?chargeback_status_pending()}) ->
    true;
is_pending(#domain_InvoicePaymentChargeback{status = _NotPending}) ->
    false.

%%----------------------------------------------------------------------------
%% @doc
%% create/2 creates a chargeback. A chargeback will not be created if
%% another one is already pending, and it will block refunds from being
%% created as well.
%%
%% Key parameters:
%%    levy: the amount of cash to be levied from the merchant.
%%    body: The sum of the chargeback.
%%            Will default to full remaining amount if undefined.
%% @end
%%----------------------------------------------------------------------------
-spec create(opts(), create_params()) ->
    {chargeback(), result()} | no_return().
create(Opts, CreateParams) ->
    do_create(Opts, CreateParams).

%%----------------------------------------------------------------------------
%% @doc
%% cancel/1 will cancel the given chargeback. All funds
%% will be trasferred back to the merchant as a result of this operation.
%% @end
%%----------------------------------------------------------------------------
-spec cancel(state()) ->
    {ok, result()} | no_return().
cancel(State) ->
    do_cancel(State).

%%----------------------------------------------------------------------------
%% @doc
%% reject/3 will reject the given chargeback, implying that no
%% sufficient evidence has been found to support the chargeback claim.
%%
%% Key parameters:
%%    levy: the amount of cash to be levied from the merchant.
%% @end
%%----------------------------------------------------------------------------
-spec reject(state(), payment_state(), reject_params()) ->
    {ok, result()} | no_return().
reject(State, PaymentState, RejectParams) ->
    do_reject(State, PaymentState, RejectParams).

%%----------------------------------------------------------------------------
%% @doc
%% accept/3 will accept the given chargeback, implying that
%% sufficient evidence has been found to support the chargeback claim. The
%% cost of the chargeback will be deducted from the merchant's account.
%%
%% Key parameters:
%%    levy: the amount of cash to be levied from the merchant.
%%          Will not change if undefined.
%%    body: The sum of the chargeback.
%%          Will not change if undefined.
%% @end
%%----------------------------------------------------------------------------
-spec accept(state(), payment_state(), accept_params()) ->
    {ok, result()} | no_return().
accept(State, PaymentState, AcceptParams) ->
    do_accept(State, PaymentState, AcceptParams).

%%----------------------------------------------------------------------------
%% @doc
%% reopen/3 will reopen the given chargeback, implying that
%% the party that initiated the chargeback was not satisfied with the result
%% and demands a new investigation. The chargeback progresses to its next
%% stage as a result of this action.
%%
%% Key parameters:
%%    levy: the amount of cash to be levied from the merchant.
%%    body: The sum of the chargeback. Will not change if undefined.
%% @end
%%----------------------------------------------------------------------------
-spec reopen(state(), payment_state(), reopen_params()) ->
    {ok, result()} | no_return().
reopen(State, PaymentState, ReopenParams) ->
    do_reopen(State, PaymentState, ReopenParams).

%

-spec merge_change(change(), state()) ->
    state().
merge_change(?chargeback_created(Chargeback), State) ->
    set(Chargeback, State);
merge_change(?chargeback_levy_changed(Levy), State) ->
    set_levy(Levy, State);
merge_change(?chargeback_body_changed(Body), State) ->
    set_body(Body, State);
merge_change(?chargeback_stage_changed(Stage), State) ->
    set_stage(Stage, State);
merge_change(?chargeback_target_status_changed(Status), State) ->
    set_target_status(Status, State);
merge_change(?chargeback_status_changed(Status), State) ->
    set_target_status(undefined, set_status(Status, State));
merge_change(?chargeback_cash_flow_changed(CashFlow), State) ->
    set_cash_flow(CashFlow, State).

-spec process_timeout(activity(), state(), action(), opts()) ->
    result().
process_timeout(preparing_initial_cash_flow, State, _Action, Opts) ->
    update_cash_flow(State, hg_machine_action:new(), Opts);
process_timeout(updating_cash_flow, State, _Action, Opts) ->
    update_cash_flow(State, hg_machine_action:instant(), Opts);
process_timeout(finalising_accounter, State, Action, Opts) ->
    finalise(State, Action, Opts).

%% Private

-spec do_create(opts(), create_params()) ->
    {chargeback(), result()} | no_return().
do_create(Opts, CreateParams = ?chargeback_params(Levy, Body)) ->
    ServiceTerms = get_service_terms(Opts, hg_domain:head()),
    _ = validate_currency(Body, get_opts_payment(Opts)),
    _ = validate_currency(Levy, get_opts_payment(Opts)),
    _ = validate_body_amount(Body, get_opts_payment_state(Opts)),
    _ = validate_service_terms(ServiceTerms),
    _ = validate_chargeback_is_allowed(ServiceTerms),
    Chargeback = build_chargeback(Opts, CreateParams),
    Action     = hg_machine_action:instant(),
    Result     = {[?chargeback_created(Chargeback)], Action},
    {Chargeback, Result}.

-spec do_cancel(state()) ->
    {ok, result()} | no_return().
do_cancel(State) ->
    _ = validate_not_initialising(State),
    _ = validate_chargeback_is_pending(State),
    _ = validate_stage_is_chargeback(State),
    Action = hg_machine_action:instant(),
    Status = ?chargeback_status_cancelled(),
    Result = {[?chargeback_target_status_changed(Status)], Action},
    {ok, Result}.

-spec do_reject(state(), payment_state(), reject_params()) ->
    {ok, result()} | no_return().
do_reject(State, PaymentState, RejectParams = ?reject_params(Levy)) ->
    _ = validate_chargeback_is_pending(State),
    _ = validate_currency(Levy, hg_invoice_payment:get_payment(PaymentState)),
    Result = build_reject_result(State, RejectParams),
    {ok, Result}.

-spec do_accept(state(), payment_state(), accept_params()) ->
    {ok, result()} | no_return().
do_accept(State, PaymentState, AcceptParams = ?accept_params(Levy, Body)) ->
    _ = validate_chargeback_is_pending(State),
    _ = validate_currency(Body, hg_invoice_payment:get_payment(PaymentState)),
    _ = validate_currency(Levy, hg_invoice_payment:get_payment(PaymentState)),
    _ = validate_body_amount(Body, PaymentState),
    Result = build_accept_result(State, AcceptParams),
    {ok, Result}.

-spec do_reopen(state(), payment_state(), reopen_params()) ->
    {ok, result()} | no_return().
do_reopen(State, PaymentState, ReopenParams = ?reopen_params(Levy, Body)) ->
    _ = validate_chargeback_is_rejected(State),
    _ = validate_not_arbitration(State),
    _ = validate_currency(Body, hg_invoice_payment:get_payment(PaymentState)),
    _ = validate_currency(Levy, hg_invoice_payment:get_payment(PaymentState)),
    _ = validate_body_amount(Body, PaymentState),
    Result = build_reopen_result(State, ReopenParams),
    {ok, Result}.

%%

-spec update_cash_flow(state(), action(), opts()) ->
    result() | no_return().
update_cash_flow(State, Action, Opts) ->
    FinalCashFlow = build_chargeback_cash_flow(State, Opts),
    UpdatedPlan   = build_updated_plan(FinalCashFlow, State),
    _             = prepare_cash_flow(State, UpdatedPlan, Opts),
    {[?chargeback_cash_flow_changed(FinalCashFlow)], Action}.

-spec finalise(state(), action(), opts()) ->
    result() | no_return().
finalise(#chargeback_st{target_status = Status}, Action, _Opts)
when Status =:= ?chargeback_status_pending() ->
    {[?chargeback_status_changed(Status)], Action};
finalise(State = #chargeback_st{target_status = Status}, Action, Opts)
when Status =:= ?chargeback_status_cancelled() ->
    _ = rollback_cash_flow(State, Opts),
    {[?chargeback_status_changed(Status)], Action};
finalise(State = #chargeback_st{target_status = Status}, Action, Opts)
when Status =:= ?chargeback_status_rejected();
     Status =:= ?chargeback_status_accepted() ->
    _ = commit_cash_flow(State, Opts),
    {[?chargeback_status_changed(Status)], Action}.

-spec build_chargeback(opts(), create_params()) ->
    chargeback() | no_return().
build_chargeback(Opts, Params = ?chargeback_params(Levy, Body, Reason)) ->
    Revision      = hg_domain:head(),
    PartyRevision = get_opts_party_revision(Opts),
    #domain_InvoicePaymentChargeback{
        id              = Params#payproc_InvoicePaymentChargebackParams.id,
        levy            = Levy,
        body            = define_body(Body, get_opts_payment_state(Opts)),
        created_at      = hg_datetime:format_now(),
        stage           = ?chargeback_stage_chargeback(),
        status          = ?chargeback_status_pending(),
        domain_revision = Revision,
        party_revision  = PartyRevision,
        reason          = Reason
    }.

-spec build_reject_result(state(), reject_params()) ->
    result() | no_return().
build_reject_result(State, ?reject_params(ParamsLevy)) ->
    Levy         = get_levy(State),
    Action       = hg_machine_action:instant(),
    LevyChange   = levy_change(ParamsLevy, Levy),
    Status       = ?chargeback_status_rejected(),
    StatusChange = [?chargeback_target_status_changed(Status)],
    Changes      = lists:append([LevyChange, StatusChange]),
    {Changes, Action}.

-spec build_accept_result(state(), accept_params()) ->
    result() | no_return().
build_accept_result(State, ?accept_params(ParamsLevy, ParamsBody)) ->
    Body         = get_body(State),
    Levy         = get_levy(State),
    Action       = hg_machine_action:instant(),
    BodyChange   = body_change(ParamsBody, Body),
    LevyChange   = levy_change(ParamsLevy, Levy),
    Status       = ?chargeback_status_accepted(),
    StatusChange = [?chargeback_target_status_changed(Status)],
    Changes      = lists:append([BodyChange, LevyChange, StatusChange]),
    {Changes, Action}.

-spec build_reopen_result(state(), reopen_params()) ->
    result() | no_return().
build_reopen_result(State, ?reopen_params(ParamsLevy, ParamsBody)) ->
    Body         = get_body(State),
    Levy         = get_levy(State),
    Stage        = get_next_stage(State),
    Action       = hg_machine_action:instant(),
    BodyChange   = body_change(ParamsBody, Body),
    LevyChange   = levy_change(ParamsLevy, Levy),
    StageChange  = [?chargeback_stage_changed(Stage)],
    Status       = ?chargeback_status_pending(),
    StatusChange = [?chargeback_target_status_changed(Status)],
    Changes      = lists:append([StageChange, BodyChange, LevyChange, StatusChange]),
    {Changes, Action}.

-spec build_chargeback_cash_flow(state(), opts()) ->
    cash_flow() | no_return().
build_chargeback_cash_flow(State, Opts) ->
    Revision        = get_revision(State),
    Payment         = get_opts_payment(Opts),
    ServiceTerms    = get_service_terms(Opts, Revision),
    Invoice         = get_opts_invoice(Opts),
    Route           = get_opts_route(Opts),
    Party           = get_opts_party(Opts),
    CreatedAt       = get_invoice_created_at(Invoice),
    ShopID          = get_invoice_shop_id(Invoice),
    Shop            = hg_party:get_shop(ShopID, Party),
    ContractID      = get_shop_contract_id(Shop),
    Contract        = hg_party:get_contract(ContractID, Party),
    VS              = collect_validation_varset(Party, Shop, Payment, State),
    TermSet         = hg_party:get_terms(Contract, CreatedAt, Revision),
    ServiceTerms    = get_merchant_chargeback_terms(TermSet),
    PaymentsTerms   = hg_routing:get_payments_terms(Route, Revision),
    ProviderTerms   = get_provider_chargeback_terms(PaymentsTerms, Payment),
    CashFlow        = collect_chargeback_cash_flow(ServiceTerms, ProviderTerms, VS, Revision),
    PmntInstitution = get_payment_institution(Contract, Revision),
    Provider        = get_route_provider(Route, Revision),
    AccountMap      = collect_account_map(Payment, Shop, PmntInstitution, Provider, VS, Revision),
    Context         = build_cash_flow_context(State),
    hg_cashflow:finalize(CashFlow, Context, AccountMap).

collect_chargeback_cash_flow(MerchantTerms, ProviderTerms, VS, Revision) ->
    #domain_PaymentChargebackServiceTerms{fees = MerchantCashflowSelector} = MerchantTerms,
    #domain_PaymentChargebackProvisionTerms{cash_flow = ProviderCashflowSelector} = ProviderTerms,
    MerchantCF = reduce_selector(merchant_chargeback_fees, MerchantCashflowSelector, VS, Revision),
    ProviderCF = reduce_selector(provider_chargeback_cash_flow, ProviderCashflowSelector, VS, Revision),
    MerchantCF ++ ProviderCF.

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
    ProviderAccount = hg_payment_institution:choose_provider_account(Currency, ProviderAccounts),
    SystemAccount   = hg_payment_institution:get_system_account(Currency, VS, Revision, PaymentInstitution),
    M = #{
        {merchant , settlement} => MerchantAccount#domain_ShopAccount.settlement     ,
        {merchant , guarantee } => MerchantAccount#domain_ShopAccount.guarantee      ,
        {provider , settlement} => ProviderAccount#domain_ProviderAccount.settlement ,
        {system   , settlement} => SystemAccount#domain_SystemAccount.settlement     ,
        {system   , subagent  } => SystemAccount#domain_SystemAccount.subagent
    },
    % External account probably can be optional for some payments
    case hg_payment_institution:choose_external_account(Currency, VS, Revision) of
        #domain_ExternalAccount{income = Income, outcome = Outcome} ->
            M#{
                {external, income} => Income,
                {external, outcome} => Outcome
            };
        undefined ->
            M
    end.

build_cash_flow_context(State = #chargeback_st{target_status = ?chargeback_status_rejected()}) ->
    ?cash(_Amount, SymCode) = get_body(State),
    #{operation_amount => ?cash(0, SymCode), surplus => get_levy(State)};
build_cash_flow_context(State) ->
    #{operation_amount => get_body(State), surplus => get_levy(State)}.

reduce_selector(Name, Selector, VS, Revision) ->
    case hg_selector:reduce(Selector, VS, Revision) of
        {value, V} ->
            V;
        Ambiguous ->
            error({misconfiguration, {'Could not reduce selector to a value', {Name, Ambiguous}}})
    end.

get_merchant_chargeback_terms(#domain_TermSet{payments = PaymentsTerms}) ->
    get_merchant_chargeback_terms(PaymentsTerms);
get_merchant_chargeback_terms(#domain_PaymentsServiceTerms{chargebacks = Terms}) ->
    Terms.

% get_provider_chargeback_terms(#domain_PaymentsProvisionTerms{chargebacks = undefined}, Payment) ->
%     error({misconfiguration, {'No chargeback terms for a payment', Payment}});
get_provider_chargeback_terms(#domain_PaymentsProvisionTerms{chargebacks = Terms}, _Payment) ->
    Terms.

define_body(undefined, PaymentState) ->
    hg_invoice_payment:get_remaining_payment_balance(PaymentState);
define_body(Cash, _PaymentState) ->
    Cash.

prepare_cash_flow(State, CashFlowPlan, Opts) ->
    PlanID = construct_chargeback_plan_id(State, Opts),
    hg_accounting:plan(PlanID, CashFlowPlan).

commit_cash_flow(State, Opts) ->
    CashFlowPlan = get_current_plan(State),
    PlanID       = construct_chargeback_plan_id(State, Opts),
    hg_accounting:commit(PlanID, CashFlowPlan).

rollback_cash_flow(State, Opts) ->
    CashFlowPlan = get_current_plan(State),
    PlanID       = construct_chargeback_plan_id(State, Opts),
    hg_accounting:rollback(PlanID, CashFlowPlan).

construct_chargeback_plan_id(State, Opts) ->
    {Stage, _} = get_stage(State),
    hg_utils:construct_complex_id([
        get_opts_invoice_id(Opts),
        get_opts_payment_id(Opts),
        {chargeback, get_id(State)},
        genlib:to_binary(Stage)
    ]).

collect_validation_varset(Party, Shop, Payment, State) ->
    #domain_Party{id = PartyID} = Party,
    #domain_Shop{
        id       = ShopID,
        category = Category,
        account  = #domain_ShopAccount{currency = Currency}
    } = Shop,
    #{
        party_id     => PartyID,
        shop_id      => ShopID,
        category     => Category,
        currency     => Currency,
        cost         => get_body(State),
        payment_tool => get_payment_tool(Payment)
    }.

%% Validations

validate_chargeback_is_allowed(#domain_PaymentChargebackServiceTerms{allow = {constant, true}}) ->
    ok;
validate_chargeback_is_allowed(_Terms) ->
    throw(#payproc_OperationNotPermitted{}).

validate_service_terms(#domain_PaymentChargebackServiceTerms{}) ->
    ok;
validate_service_terms(undefined) ->
    throw(#payproc_OperationNotPermitted{}).

validate_body_amount(undefined, _PaymentState) ->
    ok;
validate_body_amount(?cash(_, _) = Cash, PaymentState) ->
    InterimPaymentAmount = hg_invoice_payment:get_remaining_payment_balance(PaymentState),
    PaymentAmount = hg_cash:sub(InterimPaymentAmount, Cash),
    validate_remaining_payment_amount(PaymentAmount, InterimPaymentAmount).

validate_remaining_payment_amount(?cash(Amount, _), _) when Amount >= 0 ->
    ok;
validate_remaining_payment_amount(?cash(Amount, _), Maximum) when Amount < 0 ->
    throw(#payproc_InvoicePaymentAmountExceeded{maximum = Maximum}).

validate_currency(?cash(_, SymCode), #domain_InvoicePayment{cost = ?cash(_, SymCode)}) ->
    ok;
validate_currency(undefined, _Payment) ->
    ok;
validate_currency(?cash(_, SymCode), _Payment) ->
    throw(#payproc_InconsistentChargebackCurrency{currency = SymCode}).

validate_not_initialising(#chargeback_st{state = active}) ->
    ok;
validate_not_initialising(#chargeback_st{state = init}) ->
    throw(#payproc_InvoicePaymentChargebackNotFound{}).

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

%% Getters

-spec get_id(state() | chargeback()) ->
    id().
get_id(#chargeback_st{chargeback = Chargeback}) ->
    get_id(Chargeback);
get_id(#domain_InvoicePaymentChargeback{id = ID}) ->
    ID.

-spec get_current_plan(state()) ->
    [batch()].
get_current_plan(#chargeback_st{cash_flow_plans = Plans} = State) ->
    Stage = get_stage(State),
    #{Stage := Plan} = Plans,
    Plan.

-spec get_reverted_previous_stage(stage(), state()) ->
    [batch()].
get_reverted_previous_stage(?chargeback_stage_chargeback(), _State) ->
    [];
get_reverted_previous_stage(?chargeback_stage_arbitration(), State) ->
    #chargeback_st{cash_flow_plans = #{?chargeback_stage_pre_arbitration() := Plan}} = State,
    {_ID, CashFlow} = lists:last(Plan),
    [{1, hg_cashflow:revert(CashFlow)}];
get_reverted_previous_stage(?chargeback_stage_pre_arbitration(), State) ->
    #chargeback_st{cash_flow_plans = #{?chargeback_stage_chargeback() := Plan}} = State,
    {_ID, CashFlow} = lists:last(Plan),
    [{1, hg_cashflow:revert(CashFlow)}].

-spec get_revision(state() | chargeback()) ->
    hg_domain:revision().
get_revision(#chargeback_st{chargeback = Chargeback}) ->
    get_revision(Chargeback);
get_revision(#domain_InvoicePaymentChargeback{domain_revision = Revision}) ->
    Revision.

-spec get_levy(state() | chargeback()) ->
    cash().
get_levy(#chargeback_st{chargeback = Chargeback}) ->
    get_levy(Chargeback);
get_levy(#domain_InvoicePaymentChargeback{levy = Levy}) ->
    Levy.

-spec get_stage(state() | chargeback()) ->
    stage().
get_stage(#chargeback_st{chargeback = Chargeback}) ->
    get_stage(Chargeback);
get_stage(#domain_InvoicePaymentChargeback{stage = Stage}) ->
    Stage.

-spec get_next_stage(state() | chargeback()) ->
    ?chargeback_stage_pre_arbitration() | ?chargeback_stage_arbitration().
get_next_stage(#chargeback_st{chargeback = Chargeback}) ->
    get_next_stage(Chargeback);
get_next_stage(#domain_InvoicePaymentChargeback{stage = ?chargeback_stage_chargeback()}) ->
    ?chargeback_stage_pre_arbitration();
get_next_stage(#domain_InvoicePaymentChargeback{stage = ?chargeback_stage_pre_arbitration()}) ->
    ?chargeback_stage_arbitration().

% -spec get_previous_stage(state() | chargeback()) ->
%     undefined | ?chargeback_stage_pre_arbitration() | ?chargeback_stage_chargeback().
% get_next_stage(#chargeback_st{chargeback = Chargeback}) ->
%     get_next_stage(Chargeback);
% get_next_stage(#domain_InvoicePaymentChargeback{stage = ?chargeback_stage_chargeback()}) ->
%     undefined;
% get_next_stage(#domain_InvoicePaymentChargeback{stage = ?chargeback_stage_pre_arbitration()}) ->
%     ?chargeback_stage_chargeback();
% get_next_stage(#domain_InvoicePaymentChargeback{stage = ?chargeback_stage_arbitration()}) ->
%     ?chargeback_stage_pre_arbitration().

%% Setters

-spec set(chargeback(), state() | undefined) ->
    state().
set(Chargeback, undefined) ->
    #chargeback_st{chargeback = Chargeback};
set(Chargeback, #chargeback_st{} = State) ->
    State#chargeback_st{chargeback = Chargeback}.

-spec set_cash_flow(cash_flow(), state()) ->
    state().
set_cash_flow(CashFlow, #chargeback_st{cash_flow_plans = Plans} = State) ->
    Stage = get_stage(State),
    Plan = build_updated_plan(CashFlow, State),
    State#chargeback_st{cash_flow_plans = Plans#{Stage := Plan}, state = active}.

-spec set_target_status(status() | undefined, state()) ->
    state().
set_target_status(TargetStatus, #chargeback_st{} = State) ->
    State#chargeback_st{target_status = TargetStatus}.

-spec set_status(status(), state()) ->
    state().
set_status(Status, #chargeback_st{chargeback = Chargeback} = State) ->
    State#chargeback_st{
        chargeback = Chargeback#domain_InvoicePaymentChargeback{status = Status}
    }.

-spec set_body(cash(),    state()) ->
    state().
set_body(Cash, #chargeback_st{chargeback = Chargeback} = State) ->
    State#chargeback_st{
        chargeback = Chargeback#domain_InvoicePaymentChargeback{body = Cash}
    }.

-spec set_levy(cash(), state()) ->
    state().
set_levy(Cash, #chargeback_st{chargeback = Chargeback} = State) ->
    State#chargeback_st{
        chargeback = Chargeback#domain_InvoicePaymentChargeback{levy = Cash}
    }.

-spec set_stage(stage(), state()) ->
    state().
set_stage(Stage, #chargeback_st{chargeback = Chargeback} = State) ->
    State#chargeback_st{
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

get_opts_payment_state(#{payment_state := PaymentState}) ->
    PaymentState.

get_opts_payment(#{payment_state := PaymentState}) ->
    hg_invoice_payment:get_payment(PaymentState).

get_opts_route(#{payment_state := PaymentState}) ->
    hg_invoice_payment:get_route(PaymentState).

get_opts_invoice_id(Opts) ->
    #domain_Invoice{id = ID} = get_opts_invoice(Opts),
    ID.

get_opts_payment_id(Opts) ->
    #domain_InvoicePayment{id = ID} = get_opts_payment(Opts),
    ID.

get_service_terms(Opts, Revision) ->
    Invoice     = get_opts_invoice(Opts),
    Party       = get_opts_party(Opts),
    ShopID      = get_invoice_shop_id(Invoice),
    CreatedAt   = get_invoice_created_at(Invoice),
    Shop        = hg_party:get_shop(ShopID, Party),
    ContractID  = get_shop_contract_id(Shop),
    Contract    = hg_party:get_contract(ContractID, Party),
    TermSet     = hg_party:get_terms(Contract, CreatedAt, Revision),
    get_merchant_chargeback_terms(TermSet).

%%

get_payment_cost(#domain_InvoicePayment{cost = Cost}) ->
    Cost.

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

body_change(Body,        Body) -> [];
body_change(undefined,  _Body) -> [];
body_change(ParamsBody, _Body) -> [?chargeback_body_changed(ParamsBody)].

levy_change(Levy,        Levy) -> [];
levy_change(undefined,  _Levy) -> [];
levy_change(ParamsLevy, _Levy) -> [?chargeback_levy_changed(ParamsLevy)].

%%

add_batch([], CashFlow) ->
    CashFlow;
add_batch(FinalCashFlow, []) ->
    [{1, FinalCashFlow}];
add_batch(FinalCashFlow, Batches) ->
    {ID, _CF} = lists:last(Batches),
    Batches ++ [{ID + 1, FinalCashFlow}].

build_updated_plan(CashFlow, #chargeback_st{cash_flow_plans = Plans} = State) ->
    Stage = get_stage(State),
    case Plans of
        #{Stage := []} ->
            Reverted = get_reverted_previous_stage(Stage, State),
            add_batch(CashFlow, Reverted);
        #{Stage := Plan} ->
            {_, PreviousCashFlow} = lists:last(Plan),
            RevertedPrevious = hg_cashflow:revert(PreviousCashFlow),
            RevertedPlan     = add_batch(RevertedPrevious, Plan),
            add_batch(CashFlow, RevertedPlan)
    end.
