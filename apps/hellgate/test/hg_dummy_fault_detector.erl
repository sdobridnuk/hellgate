-module(hg_dummy_fault_detector).

-behaviour(application).
-behaviour(supervisor).
-behaviour(woody_server_thrift_handler).

-export([handle_function/4]).

-export([child_spec/0]).

%% Supervisor callbacks
-export([init/1]).

%% Application callbacks
-export([start/2]).
-export([stop/1]).

-spec start(normal, any()) ->
    {ok, pid()} | {error, any()}.
start(_StartType, _StartArgs) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec stop(any()) ->
    ok.

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
         port => 19999
        }
     ).

-spec handle_function(woody:func(), woody:args(), _, hg_woody_wrapper:handler_opts()) ->
    {ok, term()} | no_return().

handle_function('GetStatistics', _Args, _Context, _Options) ->
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

handle_function(_, _Args, _Context, _Options) ->
    {ok, undefined}.
