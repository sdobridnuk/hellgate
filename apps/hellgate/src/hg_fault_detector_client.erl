%%% Fault detector interaction

-module(hg_fault_detector_client).

-include_lib("fault_detector_proto/include/fd_proto_fault_detector_thrift.hrl").

%% TODO move config to a proper place
-define(DEFAULT_CONFIG,
        #fault_detector_ServiceConfig{
           sliding_window       = 60000,
           operation_time_limit = 10000,
           pre_aggregation_size = 2}).

-define(service_config(SW, OTL, PAS),
        #fault_detector_ServiceConfig{
           sliding_window       = SW,
           operation_time_limit = OTL,
           pre_aggregation_size = PAS}).

-define(operation(OpId, State),
        #fault_detector_Operation{
           operation_id = OpId,
           state        = State}).

-define(state_start(TimeStamp),  #fault_detector_Start{ time_start = TimeStamp }).
-define(state_error(TimeStamp),  #fault_detector_Error{ time_end   = TimeStamp }).
-define(state_finish(TimeStamp), #fault_detector_Finish{ time_end  = TimeStamp }).

-export([build_config/2]).
-export([build_config/3]).

-export([init_service/1]).
-export([init_service/2]).

-export([get_statistics/1]).

-export([register_operation/3]).
-export([register_operation/4]).

-type operation_status()        :: start | finish | error.
-type service_stats()           :: fd_proto_fault_detector_thrift:'ServiceStatistics'().
-type service_id()              :: fd_proto_fault_detector_thrift:'ServiceId'().
-type operation_id()            :: fd_proto_fault_detector_thrift:'OperationId'().
-type service_config()          :: fd_proto_fault_detector_thrift:'ServiceConfig'().
-type sliding_window()          :: fd_proto_fault_detector_thrift:'Milliseconds'().
-type operation_time_limit()    :: fd_proto_fault_detector_thrift:'Milliseconds'().
-type pre_aggregation_size()    :: fd_proto_fault_detector_thrift:'Seconds'() | undefined.

%% API

%%------------------------------------------------------------------------------
%% @doc
%% `build_config/2` receives the length of the sliding windown and the operation
%% time limit as arguments. The config can then be used with `init_service/2`
%% and `register_operation/4`.
%%
%% Config
%% `SlidingWindow`: pick operations from SlidingWindow milliseconds.
%% `OpTimeLimit`: expected operation execution time, in milliseconds.
%% `PreAggrSize`: time interval for data preaggregation, in seconds.
%% @end
%%------------------------------------------------------------------------------
-spec build_config(sliding_window(), operation_time_limit()) ->
    service_config().
build_config(SlidingWindow, OpTimeLimit) ->
    ?service_config(SlidingWindow, OpTimeLimit, undefined).

%%------------------------------------------------------------------------------
%% @doc
%% `build_config/3` is analogous to `build_config/2` but also receives
%% the optional pre-aggregation size argument.
%% @end
%%------------------------------------------------------------------------------
-spec build_config(sliding_window(), operation_time_limit(), pre_aggregation_size()) ->
    service_config().
build_config(SlidingWindow, OpTimeLimit, PreAggrSize) ->
    ?service_config(SlidingWindow, OpTimeLimit, PreAggrSize).
%%------------------------------------------------------------------------------
%% @doc
%% `init_service/1` receives a service id and initialises a fault detector
%% service for it, allowing you to aggregate availability statistics via
%% `register_operation/3` and `register_operation/4` and fetch it using the
%% `get_statistics/1` function.
%% @end
%%------------------------------------------------------------------------------
-spec init_service(service_id()) ->
    ok | error.
init_service(ServiceId) ->
    ServiceConfig = ?DEFAULT_CONFIG,
    do_init_service(ServiceId, ServiceConfig).

%%------------------------------------------------------------------------------
%% @doc
%% `init_service/2` is analogous to `init_service/1` but also receives
%% configuration for the fault detector service created by `build_config/3`.
%% @end
%%------------------------------------------------------------------------------
-spec init_service(service_id(), service_config()) ->
    ok | error.
init_service(ServiceId, ServiceConfig) ->
    do_init_service(ServiceId, ServiceConfig).

%%------------------------------------------------------------------------------
%% @doc
%% `get_statistics/1` receives a list of service ids and returns a
%% list of statistics on the services' reliability.
%%
%% Returns an empty list if the fault detector itself is unavailable. Services
%% not initialised in the fault detector will not be in the list.
%% @end
%%------------------------------------------------------------------------------
-spec get_statistics([service_id()]) -> [service_stats()].
get_statistics(ServiceIds) when is_list(ServiceIds) ->
    do_get_statistics(ServiceIds).

%%------------------------------------------------------------------------------
%% @doc
%% `register_operation/3` receives a service id, an operation id and an
%% operation status which is one of the following atoms: `start`, `finish`, `error`,
%% respectively for registering a start and either a successful or an erroneous
%% end of an operation. The data is then used to aggregate statistics on a
%% service's availability that is available via `get_statistics/1`.
%% @end
%%------------------------------------------------------------------------------
-spec register_operation(operation_status(), service_id(), operation_id()) ->
    ok | not_found | error.
register_operation(start, ServiceId, OperationId) ->
    OperationState  = {start, ?state_start(hg_datetime:format_now())},
    Operation       = ?operation(OperationId, OperationState),
    ServiceConfig   = ?DEFAULT_CONFIG,
    do_register_operation(ServiceId, Operation, ServiceConfig);

register_operation(finish, ServiceId, OperationId) ->
    OperationState  = {finish, ?state_finish(hg_datetime:format_now())},
    Operation       = ?operation(OperationId, OperationState),
    ServiceConfig   = ?DEFAULT_CONFIG,
    do_register_operation(ServiceId, Operation, ServiceConfig);

register_operation(error, ServiceId, OperationId) ->
    OperationState  = {error, ?state_error(hg_datetime:format_now())},
    Operation       = ?operation(OperationId, OperationState),
    ServiceConfig   = ?DEFAULT_CONFIG,
    do_register_operation(ServiceId, Operation, ServiceConfig).

%%------------------------------------------------------------------------------
%% @doc
%% `register_operation/4` is analogous to `register_operation/3` but also receives
%% configuration for the fault detector service created by `build_config/3`.
%% @end
%%------------------------------------------------------------------------------
-spec register_operation(operation_status(), service_id(), operation_id(), service_config()) ->
    ok | not_found | error.
register_operation(start, ServiceId, OperationId, ServiceConfig) ->
    OperationState  = {start, ?state_start(hg_datetime:format_now())},
    Operation       = ?operation(OperationId, OperationState),
    do_register_operation(ServiceId, Operation, ServiceConfig);

register_operation(finish, ServiceId, OperationId, ServiceConfig) ->
    OperationState  = {finish, ?state_finish(hg_datetime:format_now())},
    Operation       = ?operation(OperationId, OperationState),
    do_register_operation(ServiceId, Operation, ServiceConfig);

register_operation(error, ServiceId, OperationId, ServiceConfig) ->
    OperationState  = {error, ?state_error(hg_datetime:format_now())},
    Operation       = ?operation(OperationId, OperationState),
    do_register_operation(ServiceId, Operation, ServiceConfig).

%% PRIVATE

do_init_service(ServiceId, ServiceConfig) ->
    try hg_woody_wrapper:call(
          fault_detector,
          'InitService',
          [ServiceId, ServiceConfig]
         ) of
        {ok, _Result} -> ok;
        _Result       -> error
    catch
        _:_ -> error
    end.

do_get_statistics(ServiceIds) ->
    try hg_woody_wrapper:call(
          fault_detector,
          'GetStatistics',
          [ServiceIds]
         ) of
        {ok, Stats} -> Stats;
        _Result     -> []
    catch
        _:_ -> []
    end.

do_register_operation(ServiceId, Operation, ServiceConfig) ->
    try hg_woody_wrapper:call(
          fault_detector,
          'RegisterOperation',
          [ServiceId, Operation, ServiceConfig]
         ) of
        {ok, _Result} -> ok;
        {exception, #fault_detector_ServiceNotFoundException{}} -> not_found
    catch
        _:_ -> error
    end.
