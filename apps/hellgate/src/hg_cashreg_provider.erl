-module(hg_cashreg_provider).
-include_lib("cashreg_proto/include/cashreg_proto_proxy_provider_thrift.hrl").

-export([register_receipt/3]).
-export([handle_receipt_callback/4]).

-type receipt_context() :: cashreg_proto_proxy_provider_thrift:'ReceiptContext'().
-type session()         :: cashreg_proto_proxy_provider_thrift:'Session'().
-type proxy()           :: cashreg_proto_proxy_provider_thrift:'Proxy'().
-type callback()        :: cashreg_proto_proxy_provider_thrift:'Callback'().

-spec register_receipt(receipt_context(), session(), proxy()) ->
    term().
register_receipt(ReceiptContext, Session, Proxy) ->
    issue_call('RegisterReceipt', [ReceiptContext, Session], Proxy).

-spec handle_receipt_callback(callback(), receipt_context(), session(), proxy()) ->
    term().
handle_receipt_callback(Callback, ReceiptContext, Session, Proxy) ->
    issue_call('HandleReceiptCallback', [Callback, ReceiptContext, Session], Proxy).

issue_call(Func, Args, Proxy) ->
    hg_woody_wrapper:call(cashreg_provider, Func, Args, construct_call_options(Proxy)).

construct_call_options(#cashreg_prxprv_Proxy{url = URL}) ->
    Opts = case genlib_app:env(hellgate, proxy_opts, #{}) of
        #{transport_opts := TransportOpts = #{}} ->
            #{transport_opts => maps:to_list(maps:with([connect_timeout, recv_timeout], TransportOpts))};
        #{} ->
            #{}
    end,
    Opts#{url => URL}.
