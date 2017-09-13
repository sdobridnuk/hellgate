-module(hg_msgpack_marshalling).
-include_lib("dmsl/include/dmsl_msgpack_thrift.hrl").

%% API
-export([marshal/1]).
-export([unmarshal/1]).

-export([marshal/3]).
-export([unmarshal/3]).

-export_type([value/0]).

-type value() :: term().

-callback marshal(term(), term()) ->
    term().

%% Common marshalling

-spec marshal(value()) ->
    dmsl_msgpack_thrift:'Value'().
marshal(undefined) ->
    {nl, #msgpack_Nil{}};
marshal(Boolean) when is_boolean(Boolean) ->
    {b, Boolean};
marshal(Integer) when is_integer(Integer) ->
    {i, Integer};
marshal(Float) when is_float(Float) ->
    {flt, Float};
marshal(String) when is_binary(String) ->
    {str, String};
marshal({bin, Binary}) ->
    {bin, Binary};
marshal(Object) when is_map(Object) ->
    {obj, maps:fold(
        fun(K, V, Acc) ->
            maps:put(marshal(K), marshal(V), Acc)
        end,
        #{},
        Object
    )};
marshal(Array) when is_list(Array) ->
    {arr, lists:map(fun marshal/1, Array)}.


-spec unmarshal(dmsl_msgpack_thrift:'Value'()) ->
    value().
unmarshal({nl, #msgpack_Nil{}}) ->
    undefined;
unmarshal({b, Boolean}) ->
    Boolean;
unmarshal({i, Integer}) ->
    Integer;
unmarshal({flt, Float}) ->
    Float;
unmarshal({str, String}) ->
    String;
unmarshal({bin, Binary}) ->
    {bin, Binary};
unmarshal({obj, Object}) ->
    maps:fold(fun(K, V, Acc) -> maps:put(unmarshal(K), unmarshal(V), Acc) end, #{}, Object);
unmarshal({arr, Array}) ->
    lists:map(fun unmarshal/1, Array).

%% Marshalling that depends from module

-spec marshal(term(), value(), atom()) ->
    value().

marshal(str, String, _) when is_binary(String) ->
    String;
marshal(bin, Binary, _) when is_binary(Binary) ->
    {bin, Binary};
marshal(int, Integer, _) when is_integer(Integer) ->
    Integer;
marshal({map, str, str}, Map, _) when is_map(Map) ->
    Map;
marshal({maybe, _}, undefined, _) ->
    undefined;
marshal({maybe, Term}, Value, Module) ->
    marshal(Term, Value, Module);
marshal({list, Term}, Values, Module) when is_list(Values) ->
    [Module:marshal(Term, Value) || Value <- Values];
marshal(msgpack, Msgpack, _) ->
    unmarshal(Msgpack);
marshal(Term, Value, Module) ->
    Module:marshal(Term, Value).

-spec unmarshal(term(), value(), atom()) ->
    value().

unmarshal(str, String, _) ->
    String;
unmarshal(bin, Binary, _) ->
    Binary;
unmarshal(int, Integer, _) ->
    Integer;
unmarshal({map, str, str}, Map, _) ->
    Map;
unmarshal({maybe, _}, undefined, _) ->
    undefined;
unmarshal({maybe, Term}, Value, Module) ->
    unmarshal(Term, Value, Module);
unmarshal({list, Term}, Values, Module) when is_list(Values) ->
    [Module:unmarshal(Term, Value) || Value <- Values];
unmarshal(msgpack, Msgpack, _) ->
    marshal(Msgpack);
unmarshal(Term, Value, Module) ->
    Module:unmarshal(Term, Value).