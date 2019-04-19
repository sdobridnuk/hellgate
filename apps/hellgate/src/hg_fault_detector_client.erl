%%% Fault detector interaction

-module(hg_fault_detector_client).

-include_lib("fault_detector_proto/include/fd_proto_fault_detector_thrift.hrl").

-define(DEFAULT_CONFIG, #fault_detector_ServiceConfig{
    sliding_window = genlib_app:env(
        hellgate,
        fault_detector_default_sliding_window,
        60000
    ),
    operation_time_limit = genlib_app:env(
        hellgate,
        fault_detector_default_operation_time_limit,
        10000
    ),
    pre_aggregation_size = genlib_app:env(
        hellgate,
        fault_detector_default_pre_aggregation_size,
        2
    )
}).

-define(service_config(SW, OTL, PAS), #fault_detector_ServiceConfig{
     sliding_window       = SW,
     operation_time_limit = OTL,
     pre_aggregation_size = PAS
}).

-define(operation(OpId, State), #fault_detector_Operation{
     operation_id = OpId,
     state        = State
}).

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
    {ok, initialised} | {error, any()}.
init_service(ServiceId) ->
    call('InitService', [ServiceId, ?DEFAULT_CONFIG]).

%%------------------------------------------------------------------------------
%% @doc
%% `init_service/2` is analogous to `init_service/1` but also receives
%% configuration for the fault detector service created by `build_config/3`.
%% @end
%%------------------------------------------------------------------------------
-spec init_service(service_id(), service_config()) ->
    {ok, initialised} | {error, any()}.
init_service(ServiceId, ServiceConfig) ->
    call('InitService', [ServiceId, ServiceConfig]).

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
    call('GetStatistics', [ServiceIds]).

%%------------------------------------------------------------------------------
%% @doc
%% `register_operation/3` receives a service id, an operation id and an
%% operation status which is one of the following atoms: `start`, `finish`, `error`,
%% respectively for registering a start and either a successful or an erroneous
%% end of an operation. The data is then used to aggregate statistics on a
%% service's availability that is accessible via `get_statistics/1`.
%% @end
%%------------------------------------------------------------------------------
-spec register_operation(operation_status(), service_id(), operation_id()) ->
    {ok, registered} | {error, not_found} | {error, any()}.
register_operation(Status, ServiceId, OperationId) ->
    register_operation(Status, ServiceId, OperationId, ?DEFAULT_CONFIG).

%%------------------------------------------------------------------------------
%% @doc
%% `register_operation/4` is analogous to `register_operation/3` but also receives
%% configuration for the fault detector service created by `build_config/3`.
%% @end
%%------------------------------------------------------------------------------
-spec register_operation(operation_status(), service_id(), operation_id(), service_config()) ->
    {ok, registered} | {error, not_found} | {error, any()}.
register_operation(Status, ServiceId, OperationId, ServiceConfig) ->
    OperationState = case Status of
        start  -> {Status, ?state_start(hg_datetime:format_now())};
        error  -> {Status, ?state_error(hg_datetime:format_now())};
        finish -> {Status, ?state_finish(hg_datetime:format_now())}
    end,
    Operation = ?operation(OperationId, OperationState),
    call('RegisterOperation', [ServiceId, Operation, ServiceConfig]).

%% PRIVATE

call(Function, Args) ->
    Opts = #{url => genlib:to_binary(maps:get(fault_detector, genlib_app:env(hellgate, services)))},
    Deadline = woody_deadline:from_timeout(genlib_app:env(hellgate, fault_detector_timeout, infinity)),
    do_call(Function, Args, Opts, Deadline).

do_call('InitService', Args, Opts, Deadline) ->
    try hg_woody_wrapper:call(fault_detector, 'InitService', Args, Opts, Deadline) of
        {ok, _Result} -> {ok, initialised}
    catch
        _Error:Reason ->
            String = "Unable to init service ~p in fault detector.\n~p",
            _ = lager:error(String, [ServiceId, Reason]),
            {error, Reason}
    end;
do_call('GetStatistics', Args, Opts, Deadline) ->
    try hg_woody_wrapper:call(fault_detector, 'GetStatistics', Args, Opts, Deadline) of
        {ok, Stats} -> Stats
    catch
        _Error:Reason ->
            String = "Unable to get statistics from fault detector.\n~p",
            _ = lager:error(String, [Reason]),
            []
    end;
do_call('RegisterOperation', Args, Opts, Deadline) ->
    try hg_woody_wrapper:call(fault_detector, 'RegisterOperation', Args, Opts, Deadline) of
        {ok, _Result} ->
            {ok, registered};
        {exception, #fault_detector_ServiceNotFoundException{}} ->
            {error, not_found}
    catch
        _Error:Reason ->
            String = "Unable to register operation ~p, for service ~p in fault detector.\n~p",
            _ = lager:error(String, [Operation, ServiceId, Reason]),
            {error, Reason}
    end.
