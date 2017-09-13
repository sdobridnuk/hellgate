-module(hg_content).
-include_lib("dmsl/include/dmsl_base_thrift.hrl").

%% Msgpack marshalling callbacks

-behaviour(hg_msgpack_marshalling).

-export([marshal/2]).
-export([unmarshal/2]).

%% Marshalling

-spec marshal(term(), term()) ->
    term().

marshal(content, #'Content'{type = Type, data = Data}) ->
    [
        marshal(str, Type),
        marshal(bin, Data)
    ];

marshal(Term, Value) ->
    hg_msgpack_marshalling:marshal(Term, Value, ?MODULE).

%% Unmarshalling

-spec unmarshal(term(), term()) ->
    term().

unmarshal(content, [Type, {bin, Data}]) ->
    #'Content'{
        type = unmarshal(str, Type),
        data = unmarshal(bin, Data)
    };

unmarshal(content, {'Content', Type, Data}) ->
    #'Content'{
        type = unmarshal(str, Type),
        data = unmarshal(bin, Data)
    };

unmarshal(Term, Value) ->
    hg_msgpack_marshalling:unmarshal(Term, Value, ?MODULE).