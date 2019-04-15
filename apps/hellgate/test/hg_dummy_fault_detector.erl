-module(hg_dummy_fault_detector).

-behaviour(woody_server_thrift_handler).

-export([child_spec/0]).

-export([handle_function/4]).

-include_lib("fault_detector_proto/include/fd_proto_fault_detector_thrift.hrl").

-spec child_spec() ->
    term().
child_spec() ->
    woody_server:child_spec(
      ?MODULE,
      #{
         handlers => [{"/", {{fd_proto_fault_detector_thrift, 'FaultDetector'}, ?MODULE}}],
         event_handler => scoper_woody_event_handler,
         ip => {127,0,0,1},
         port => 20001
        }
     ).

-spec handle_function(woody:func(), woody:args(), _, hg_woody_wrapper:handler_opts()) ->
    {ok, term()} | no_return().

handle_function('GetStatistics', [[<<"200">>, <<"201">>]], _Context, _Options) ->
    {ok, [
          #fault_detector_ServiceStatistics{
             service_id = <<"200">>,
             failure_rate = 1.0,
             operations_count = 322,
             error_operations_count = 322,
             overtime_operations_count = 0,
             success_operations_count = 0
            },
          #fault_detector_ServiceStatistics{
             service_id = <<"201">>,
             failure_rate = 0.0,
             operations_count = 322,
             error_operations_count = 0,
             overtime_operations_count = 0,
             success_operations_count = 322
            }
         ]};

handle_function('GetStatistics', _Args, _Context, _Options) ->
    {ok, []};

handle_function(_, _Args, _Context, _Options) ->
    {ok, undefined}.
