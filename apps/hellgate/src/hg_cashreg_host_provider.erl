-module(hg_cashreg_host_provider).
-include_lib("cashreg_proto/include/cashreg_proto_proxy_provider_thrift.hrl").

-behaviour(hg_woody_wrapper).

-export([handle_function/3]).

-type tag()           :: cashreg_proto_proxy_provider_thrift:'Tag'().
-type callback()      :: cashreg_proto_proxy_provider_thrift:'Callback'().

-spec handle_function('ProcessReceiptCallback', [tag() | callback()], hg_woody_wrapper:handler_opts()) ->
    term() | no_return().

handle_function('ProcessReceiptCallback', [Tag, Callback], _) ->
    map_error(hg_cashreg_controller:process_callback(Tag, {provider, Callback})).

map_error({ok, Response}) ->
    Response;
map_error({error, Reason}) ->
    error(Reason).