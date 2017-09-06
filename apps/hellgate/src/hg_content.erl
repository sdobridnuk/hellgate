-module(hg_content).
-include_lib("dmsl/include/dmsl_base_thrift.hrl").

-export([marshal/1]).
-export([unmarshal/1]).

%% Msgpack marshalling callbacks

-behaviour(hg_msgpack_marshalling).

-export([marshal/2]).
-export([unmarshal/2]).

-type content() :: dmsl_base_thrift:'Content'().

%% Marshalling

-spec marshal(content()) ->
    hg_msgpack_marshalling:value().

marshal(Content) ->
    marshal({maybe, content}, Content).

-spec marshal(term(), content()) ->
    hg_msgpack_marshalling:value().

marshal(content, #'Content'{type = Type, data = Data}) ->
    [
        marshal(str, Type),
        marshal(bin, Data)
    ];

marshal(Term, Value) ->
    hg_msgpack_marshalling:marshal(Term, Value, ?MODULE).

%% Unmarshalling

-spec unmarshal(hg_msgpack_marshalling:value()) ->
    content().

unmarshal(Content) ->
    unmarshal({maybe, content}, Content).

-spec unmarshal(term(), hg_msgpack_marshalling:value()) ->
    content().

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