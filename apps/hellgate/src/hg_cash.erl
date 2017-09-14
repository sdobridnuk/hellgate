-module(hg_cash).
-include_lib("dmsl/include/dmsl_domain_thrift.hrl").
-include("domain.hrl").

-export([marshal/2]).
-export([unmarshal/2]).

%% Marshalling

-spec marshal(term(), term()) ->
    term().

marshal(cash, ?cash(Amount, SymbolicCode)) ->
    [2, [marshal(int, Amount), marshal(str, SymbolicCode)]];

marshal(Term, Value) ->
    hg_msgpack_marshalling:marshal(Term, Value, ?MODULE).

%% Unmarshalling

-spec unmarshal(term(), term()) ->
    term().

unmarshal(cash, [2, [Amount, SymbolicCode]]) ->
    ?cash(unmarshal(int, Amount), unmarshal(str, SymbolicCode));

unmarshal(cash, [1, {'domain_Cash', Amount, {'domain_CurrencyRef', SymbolicCode}}]) ->
    ?cash(unmarshal(int, Amount), unmarshal(str, SymbolicCode));

unmarshal(Term, Value) ->
    hg_msgpack_marshalling:unmarshal(Term, Value, ?MODULE).
