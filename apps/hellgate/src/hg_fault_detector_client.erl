%%% Fault detector interaction

-module(hg_fault_detector_client).

-include_lib("fault_detector_proto/include/fd_proto_fault_detector_thrift.hrl").

%% TODO move config to a proper place
-define(RETRIES, 5).

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

-export([init_service/1]).
-export([init_service/4]).

-export([get_statistics/1]).

-export([register_operation/3]).
-export([register_operation/6]).

-type service_stats()           :: fd_proto_fault_detector_thrift:'ServiceStatistics'().
-type service_id()              :: binary().
-type operation_id()            :: binary().
-type operation_status()        :: start | finish | error.
-type sliding_window()          :: non_neg_integer().
-type operation_time_limit()    :: non_neg_integer().
-type pre_aggregation_size()    :: non_neg_integer() | undefined.

-type woody_result()            :: {ok, woody:result()}
                                 | {exception, woody_error:business_error()}
                                 | no_return().

%% API

%%------------------------------------------------------------------------------
%% @doc
%% init_service/1 receives a service id and initialises a fault detector
%% service for it, allowing you to aggregate availability statistics via
%% register_operation/3 and register_operation/6 and fetch it using the
%% get_statistics/1 function.
%% @end
%%------------------------------------------------------------------------------
-spec init_service(service_id()) ->
    woody_result().
init_service(ServiceId) ->
    ServiceConfig = ?DEFAULT_CONFIG,
    do_init_service(ServiceId, ServiceConfig).

%%------------------------------------------------------------------------------
%% @doc
%% init_service/4 is analogous to init_service/1 but also receives
%% configuration for the fault detector service.
%%
%% Config
%% SlidingWindow: pick operations from SlidingWindow milliseconds
%% OpTimeLimit: expected operation execution time
%% PreAggrSize: time interval for data preaggregation
%% @end
%%------------------------------------------------------------------------------
-spec init_service(service_id(),
                   sliding_window(),
                   operation_time_limit(),
                   pre_aggregation_size()) ->
    woody_result().
init_service(ServiceId, SlidingWindow, OpTimeLimit, PreAggrSize) ->
    ServiceConfig = ?service_config(SlidingWindow, OpTimeLimit, PreAggrSize),
    do_init_service(ServiceId, ServiceConfig).

%%------------------------------------------------------------------------------
%% @doc
%% get_statistics/1 receives a list of service ids and returns a
%% list of statistics on the services' reliability.
%%
%% Returns an empty list if the fault detector itself is unavailable.
%% @end
%%------------------------------------------------------------------------------
-spec get_statistics([service_id()]) -> [service_stats()].
get_statistics(ServiceIds) when is_list(ServiceIds) ->
    do_get_statistics(ServiceIds, ?RETRIES).

%%------------------------------------------------------------------------------
%% @doc
%% register_operation/3 receives a service id, an operation id and an
%% operation status which is one of the following atoms: start, finish, error,
%% respectively for registering a start and either a successful or an erroneous
%% end of an operation. The data is then used to aggregate statistics on a
%% service's availability that is available via get_statistics/1
%% @end
%%------------------------------------------------------------------------------
-spec register_operation(service_id(), operation_id(), operation_status()) ->
    woody_result().
register_operation(ServiceId, OperationId, start) ->
    OperationState  = {start, #fault_detector_Start{ time_start = hg_datetime:format_now()} },
    Operation       = ?operation(OperationId, OperationState),
    ServiceConfig   = ?DEFAULT_CONFIG,
    do_register_operation(ServiceId, Operation, ServiceConfig);

register_operation(ServiceId, OperationId, finish) ->
    OperationState  = {finish, #fault_detector_Finish{ time_end = hg_datetime:format_now()} },
    Operation       = ?operation(OperationId, OperationState),
    ServiceConfig   = ?DEFAULT_CONFIG,
    do_register_operation(ServiceId, Operation, ServiceConfig);

register_operation(ServiceId, OperationId, error) ->
    OperationState  = {error, #fault_detector_Error{ time_end = hg_datetime:format_now()} },
    Operation       = ?operation(OperationId, OperationState),
    ServiceConfig   = ?DEFAULT_CONFIG,
    do_register_operation(ServiceId, Operation, ServiceConfig).

%%------------------------------------------------------------------------------
%% @doc
%% register_operation/6 is analogous to register_operation/3 but also receives
%% configuration for the fault detector service.
%%
%% Config
%% SlidingWindow: pick operations from SlidingWindow milliseconds
%% OpTimeLimit: expected operation execution time
%% PreAggrSize: time interval for data preaggregation
%% @end
%%------------------------------------------------------------------------------
-spec register_operation(service_id(),
                         operation_id(),
                         operation_status(),
                         sliding_window(),
                         operation_time_limit(),
                         pre_aggregation_size()) ->
    woody_result().
register_operation(ServiceId, OperationId, start, SlidingWindow, OpTimeLimit, PreAggrSize) ->
    OperationState  = {start, #fault_detector_Start{ time_start = hg_datetime:format_now()} },
    Operation       = ?operation(OperationId, OperationState),
    ServiceConfig   = ?service_config(SlidingWindow, OpTimeLimit, PreAggrSize),
    do_register_operation(ServiceId, Operation, ServiceConfig);

register_operation(ServiceId, OperationId, finish, SlidingWindow, OpTimeLimit, PreAggrSize) ->
    OperationState  = {finish, #fault_detector_Finish{ time_end = hg_datetime:format_now()} },
    Operation       = ?operation(OperationId, OperationState),
    ServiceConfig   = ?service_config(SlidingWindow, OpTimeLimit, PreAggrSize),
    do_register_operation(ServiceId, Operation, ServiceConfig);

register_operation(ServiceId, OperationId, error, SlidingWindow, OpTimeLimit, PreAggrSize) ->
    OperationState  = {error, #fault_detector_Error{ time_end = hg_datetime:format_now()} },
    Operation       = ?operation(OperationId, OperationState),
    ServiceConfig   = ?service_config(SlidingWindow, OpTimeLimit, PreAggrSize),
    do_register_operation(ServiceId, Operation, ServiceConfig).

%% PRIVATE

%% TODO: maybe log fd unavailability?
do_init_service(ServiceId, ServiceConfig) ->
    hg_woody_wrapper:call(fault_detector, 'InitService', [ServiceId, ServiceConfig]).

%% @doc
do_get_statistics(_ServiceIds, 0) -> [];
do_get_statistics(ServiceIds, Retries) ->
    try hg_woody_wrapper:call(fault_detector, 'GetStatistics', [ServiceIds]) of
        {ok, Stats} -> Stats;
        _Result     -> []
    catch
        _:_ -> do_get_statistics(ServiceIds, Retries - 1)
    end.

do_register_operation(ServiceId, Operation, ServiceConfig) ->
    hg_woody_wrapper:call(fault_detector, 'RegisterOperation', [ServiceId, Operation, ServiceConfig]).
