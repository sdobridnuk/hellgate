%%% Fault detector interaction

-module(hg_fault_detector_client).

-include_lib("fault_detector_proto/include/fd_proto_fault_detector_thrift.hrl").

-define(DEFAULT_CONFIG, #fault_detector_ServiceConfig{
                         sliding_window = 60000,
                         operation_time_limit = 10000,
                         pre_aggregation_size = 2}).

-export([init_service/1]).
-export([init_service/4]).

-export([get_statistics/1]).

-export([register_operation/3]).
-export([register_operation/6]).

-type service_id()              :: binary().
-type operation_id()            :: binary().
-type operation_status()        :: start | finish | error.
-type sliding_window()          :: non_neg_integer().
-type operation_time_limit()    :: non_neg_integer().
-type pre_aggregation_size()    :: non_neg_integer() | undefined.

% -type service_stats()   :: fd_proto_fault_detector_thrift:'ServiceStatistics'().
% -type service_config()  :: fd_proto_fault_detector_thrift:'ServiceConfig'().
% -type operation()       :: fd_proto_fault_detector_thrift:'Operation'().

-spec init_service(service_id()) ->
    {ok, woody:result()}
    | {exception, woody_error:business_error()}
    | no_return().
init_service(ServiceId) ->
    do_init_service(ServiceId, ?DEFAULT_CONFIG).

-spec init_service(service_id(),
                   sliding_window(),
                   operation_time_limit(),
                   pre_aggregation_size()) ->
    {ok, woody:result()}
    | {exception, woody_error:business_error()}
    | no_return().
init_service(ServiceId, SlidingWindow, OpTimeLimit, PreAggrSize) ->
    do_init_service(
        ServiceId,
        #fault_detector_ServiceConfig{
            sliding_window       = SlidingWindow,
            operation_time_limit = OpTimeLimit,
            pre_aggregation_size = PreAggrSize}).

-spec get_statistics([service_id()]) ->
    {ok, woody:result()}
    | {exception, woody_error:business_error()}
    | no_return().
get_statistics(ServiceIds) when is_list(ServiceIds) ->
    do_get_statistics(ServiceIds).

-spec register_operation(service_id(), operation_id(), operation_status()) ->
    {ok, woody:result()}
    | {exception, woody_error:business_error()}
    | no_return().
register_operation(ServiceId, OperationId, OperationStatus) ->
    do_register_operation(ServiceId, OperationId, OperationStatus, ?DEFAULT_CONFIG).

-spec register_operation(service_id(),
                         operation_id(),
                         operation_status(),
                         sliding_window(),
                         operation_time_limit(),
                         pre_aggregation_size()) ->
    {ok, woody:result()}
    | {exception, woody_error:business_error()}
    | no_return().
register_operation(ServiceId, OperationId, OperationStatus, SlidingWindow, OpTimeLimit, PreAggrSize) ->
    do_register_operation(
        ServiceId,
        OperationId,
        OperationStatus,
        #fault_detector_ServiceConfig{
            sliding_window       = SlidingWindow,
            operation_time_limit = OpTimeLimit,
            pre_aggregation_size = PreAggrSize}).

%% PRIVATE

do_init_service(ServiceId, ServiceConfig) ->
    woody_client:call(
        {{fd_proto_fault_detector_thrift, 'FaultDetector'},
         'InitService',
         [ServiceId, ServiceConfig]},
        #{url => fd_url(), event_handler => woody_event_handler_default}).

do_get_statistics(ServiceIds) ->
    woody_client:call(
        {{fd_proto_fault_detector_thrift, 'FaultDetector'},
         'ServiceStatistics',
         [ServiceIds]},
        #{url => fd_url(), event_handler => woody_event_handler_default}).

do_register_operation(ServiceId, OperationId, OperationStatus, ServiceConfig) ->
    OperationState =
        case OperationStatus of
            start ->
                {OperationStatus, #fault_detector_Start{time_start = hg_datetime:format_now()}};
            finish ->
                {OperationStatus, #fault_detector_Finish{time_end = hg_datetime:format_now()}};
            error ->
                {OperationStatus, #fault_detector_Error{time_end = hg_datetime:format_now()}}
        end,
    Operation = #fault_detector_Operation{operation_id = OperationId, state = OperationState},
    woody_client:call(
        {{fd_proto_fault_detector_thrift, 'FaultDetector'},
         'RegisterOperation',
         [ServiceId, Operation, ServiceConfig]},
        #{url => fd_url(), event_handler => woody_event_handler_default}).

fd_url() ->
    #{fault_detector := Url} = genlib_app:env(hellgate, services),
    Url.
