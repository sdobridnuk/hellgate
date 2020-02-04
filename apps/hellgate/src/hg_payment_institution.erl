-module(hg_payment_institution).

-include_lib("damsel/include/dmsl_domain_thrift.hrl").

%%

-export([get_system_account/4]).
-export([get_realm/1]).
-export([is_live/1]).
-export([choose_provider_account/2]).

%%

-type currency()        :: dmsl_domain_thrift:'CurrencyRef'().
-type varset()          :: hg_selector:varset().
-type revision()        :: hg_domain:revision().
-type payment_inst()    :: dmsl_domain_thrift:'PaymentInstitution'().
-type realm()           :: dmsl_domain_thrift:'PaymentInstitutionRealm'().
-type accounts()        :: dmsl_domain_thrift:'ProviderAccountSet'().
-type account()         :: dmsl_domain_thrift:'ProviderAccount'().

%%

-spec get_system_account(currency(), varset(), revision(), payment_inst()) ->
    dmsl_domain_thrift:'SystemAccount'() | no_return().

get_system_account(Currency, VS, Revision, #domain_PaymentInstitution{system_account_set = S}) ->
    SystemAccountSetRef = hg_selector:reduce_to_value(S, VS, Revision),
    SystemAccountSet = hg_domain:get(Revision, {system_account_set, SystemAccountSetRef}),
    case maps:find(Currency, SystemAccountSet#domain_SystemAccountSet.accounts) of
        {ok, Account} ->
            Account;
        error ->
            error({misconfiguration, {'No system account for a given currency', Currency}})
    end.

-spec get_realm(payment_inst()) -> realm().

get_realm(#domain_PaymentInstitution{realm = Realm}) ->
    Realm.

-spec is_live(payment_inst()) -> boolean().

is_live(#domain_PaymentInstitution{realm = Realm}) ->
    Realm =:= live.

-spec choose_provider_account(currency(), accounts()) -> account() | no_return().

choose_provider_account(Currency, Accounts) ->
    case maps:find(Currency, Accounts) of
        {ok, Account} ->
            Account;
        error ->
            error({misconfiguration, {'No provider account for a given currency', Currency}})
    end.
