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

-spec init_service(service_id()) ->
    woody_result().
init_service(ServiceId) ->
    ServiceConfig = ?DEFAULT_CONFIG,
    do_init_service(ServiceId, ServiceConfig).

-spec init_service(service_id(),
                   sliding_window(),
                   operation_time_limit(),
                   pre_aggregation_size()) ->
    woody_result().
init_service(ServiceId, SlidingWindow, OpTimeLimit, PreAggrSize) ->
    ServiceConfig = ?service_config(SlidingWindow, OpTimeLimit, PreAggrSize),
    do_init_service(ServiceId, ServiceConfig).

-spec get_statistics([service_id()]) -> [service_stats()].
get_statistics(ServiceIds) when is_list(ServiceIds) ->
    do_get_statistics(ServiceIds, ?RETRIES).

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

do_init_service(ServiceId, ServiceConfig) ->
    hg_woody_wrapper:call(fault_detector, 'InitService', [ServiceId, ServiceConfig]).

do_get_statistics(_ServiceIds, 0) -> [];
do_get_statistics(ServiceIds, Retries) ->
    try
        case hg_woody_wrapper:call(fault_detector, 'GetStatistics', [ServiceIds]) of
            {ok, Stats} -> Stats;
            _Result     -> []
        end
    catch
        _ ->
            % timer:sleep(200),
            do_get_statistics(ServiceIds, Retries - 1)
    end.

do_register_operation(ServiceId, Operation, ServiceConfig) ->
    hg_woody_wrapper:call(fault_detector, 'RegisterOperation', [ServiceId, Operation, ServiceConfig]).
