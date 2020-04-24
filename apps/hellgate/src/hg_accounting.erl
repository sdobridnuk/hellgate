%%% Accounting
%%%
%%% TODO
%%%  - Brittle posting id assignment, it should be a level upper, maybe even in
%%%    `hg_cashflow`.
%%%  - Stuff cash flow details in the posting description fields.

-module(hg_accounting).

-define(FIXME_TEMPORARY_VCLOCK, <<"FIXME_TEMPORARY_VCLOCK">>).
-define(FIXME_TEMPORARY_OWN_AMOUNT, 5000000).
-define(FIXME_TEMPORARY_MAXAVAIL_AMOUNT, 5000000).
-define(FIXME_TEMPORARY_MINAVAIL_AMOUNT, 5000000).

-export([get_account/1]).
-export([get_balance/1]).
-export([get_balance/2]).
-export([create_account/1]).
-export([create_account/2]).

-export([hold/2]).
-export([plan/2]).
-export([commit/2]).
-export([rollback/2]).

-include_lib("damsel/include/dmsl_payment_processing_thrift.hrl").
-include_lib("shumpune_proto/include/shumpune_shumpune_thrift.hrl").

-type amount()          :: dmsl_domain_thrift:'Amount'().
-type currency_code()   :: dmsl_domain_thrift:'CurrencySymbolicCode'().
-type account_id()      :: dmsl_accounter_thrift:'AccountID'().
-type plan_id()         :: dmsl_accounter_thrift:'PlanID'().
-type batch_id()        :: dmsl_accounter_thrift:'BatchID'().
-type final_cash_flow() :: dmsl_domain_thrift:'FinalCashFlow'().
-type batch()           :: {batch_id(), final_cash_flow()}.
-type clock()           :: shumpune_shumpune_thrift:'Clock'().

-export_type([batch/0]).

-type account() :: #{
    account_id => account_id(),
    currency_code => currency_code()
}.

-type balance() :: #{
    account_id => account_id(),
    own_amount => amount(),
    min_available_amount => amount(),
    max_available_amount => amount()
}.

-spec get_account(account_id()) ->
    account().

get_account(_AccountID) ->
    % FIXME TEMPORARY MEASURES
    case {exception, #shumpune_AccountNotFound{}} of
        {exception, #shumpune_AccountNotFound{}} ->
            hg_woody_wrapper:raise(#payproc_AccountNotFound{})
    end.

-spec get_balance(account_id()) ->
    balance().

get_balance(AccountID) ->
    get_balance(AccountID, {latest, #shumpune_LatestClock{}}).

-spec get_balance(account_id(), clock()) ->
    balance().

get_balance(AccountID, _Clock) ->
    % FIXME TEMPORARY MEASURES
    case {ok, #shumpune_Balance{
        id                   = AccountID,
        own_amount           = ?FIXME_TEMPORARY_OWN_AMOUNT,
        max_available_amount = ?FIXME_TEMPORARY_MAXAVAIL_AMOUNT,
        min_available_amount = ?FIXME_TEMPORARY_MINAVAIL_AMOUNT,
        clock                = {vector, ?FIXME_TEMPORARY_VCLOCK}
    }} of
        {ok, Result} ->
            construct_balance(AccountID, Result)
    end.

-spec create_account(currency_code()) ->
    account_id().

create_account(CurrencyCode) ->
    create_account(CurrencyCode, undefined).

-spec create_account(currency_code(), binary() | undefined) ->
    account_id().

create_account(CurrencyCode, Description) ->
    case call_accounter('CreateAccount', [construct_prototype(CurrencyCode, Description)]) of
        {ok, Result} ->
            Result;
        {exception, Exception} ->
            error({accounting, Exception}) % FIXME
    end.

construct_prototype(CurrencyCode, Description) ->
    #shumpune_AccountPrototype{
        currency_sym_code = CurrencyCode,
        description = Description
    }.

%%
-spec plan(plan_id(), [batch()]) ->
    clock().

plan(_PlanID, []) ->
    error(badarg);
plan(_PlanID, Batches) when not is_list(Batches) ->
    error(badarg);
plan(PlanID, Batches) ->
    lists:foldl(
        fun (Batch, _) -> hold(PlanID, Batch) end,
        undefined,
        Batches
    ).

-spec hold(plan_id(), batch()) ->
    clock().

hold(PlanID, Batch) ->
    do('Hold', construct_plan_change(PlanID, Batch)).

-spec commit(plan_id(), [batch()]) ->
    clock().

commit(PlanID, Batches) ->
    do('CommitPlan', construct_plan(PlanID, Batches)).

-spec rollback(plan_id(), [batch()]) ->
    clock().

rollback(PlanID, Batches) ->
    do('RollbackPlan', construct_plan(PlanID, Batches)).

do(_Op, _Plan) ->
    % FIXME TEMPORARY MEASURES
    case {ok, {vector, ?FIXME_TEMPORARY_VCLOCK}} of
        {ok, Clock} ->
            Clock
    end.

construct_plan_change(PlanID, {BatchID, Cashflow}) ->
    #shumpune_PostingPlanChange{
        id = PlanID,
        batch = #shumpune_PostingBatch{
            id = BatchID,
            postings = collect_postings(Cashflow)
        }
    }.

construct_plan(PlanID, Batches) ->
    #shumpune_PostingPlan{
        id    = PlanID,
        batch_list = [
            #shumpune_PostingBatch{
                id = BatchID,
                postings = collect_postings(Cashflow)
            }
        || {BatchID, Cashflow} <- Batches]
    }.

collect_postings(Cashflow) ->
    [
        #shumpune_Posting{
            from_id           = Source,
            to_id             = Destination,
            amount            = Amount,
            currency_sym_code = CurrencyCode,
            description       = construct_posting_description(Details)
        }
        || #domain_FinalCashFlowPosting{
            source      = #domain_FinalCashFlowAccount{account_id = Source},
            destination = #domain_FinalCashFlowAccount{account_id = Destination},
            details     = Details,
            volume      = #domain_Cash{
                amount      = Amount,
                currency    = #domain_CurrencyRef{symbolic_code = CurrencyCode}
            }
        } <- Cashflow
    ].

construct_posting_description(Details) when is_binary(Details) ->
    Details;
construct_posting_description(undefined) ->
    <<>>.

%%

% construct_account(
%     AccountID,
%     #shumpune_Account{
%         currency_sym_code = CurrencyCode
%     }
% ) ->
%     #{
%         account_id => AccountID,
%         currency_code => CurrencyCode
%     }.

construct_balance(
    AccountID,
    #shumpune_Balance{
        own_amount = OwnAmount,
        min_available_amount = MinAvailableAmount,
        max_available_amount = MaxAvailableAmount
    }
) ->
    #{
        account_id => AccountID,
        own_amount => OwnAmount,
        min_available_amount => MinAvailableAmount,
        max_available_amount => MaxAvailableAmount
    }.

%%

call_accounter(Function, Args) ->
    hg_woody_wrapper:call(accounter, Function, Args).
