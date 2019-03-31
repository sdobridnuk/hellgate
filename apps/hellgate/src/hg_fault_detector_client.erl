%%% Fault detector interaction

-module(hg_fault_detector_client).

-include_lib("fault_detector_proto/include/fd_proto_fault_detector_thrift.hrl").

-define(URL, "::").
-define(DEFAULT_CONFIG, #fault_detector_ServiceConfig{
                         sliding_window = 60000,
                         operation_time_limit = 10000,
                         pre_aggregation_size = 2}).

-export([init_service/1]).
-export([init_service/4]).

-export([get_statistics/1]).

-export([register_operation/2]).
-export([register_operation/5]).

-type service_id()              :: binary().
-type operation()               :: binary().
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
    do_init_service(ServiceId,
                    #fault_detector_ServiceConfig{
                        sliding_window = SlidingWindow,
                        operation_time_limit = OpTimeLimit,
                        pre_aggregation_size = PreAggrSize}).

-spec get_statistics([service_id()]) ->
    {ok, woody:result()}
    | {exception, woody_error:business_error()}
    | no_return().
get_statistics(ServiceIds) when is_list(ServiceIds) ->
    do_get_statistics(ServiceIds).

-spec register_operation(service_id(), operation()) ->
    {ok, woody:result()}
    | {exception, woody_error:business_error()}
    | no_return().
register_operation(ServiceId, Operation) ->
    do_register_operation(ServiceId, Operation, ?DEFAULT_CONFIG).

-spec register_operation(service_id(),
                         operation(),
                         sliding_window(),
                         operation_time_limit(),
                         pre_aggregation_size()) ->
    {ok, woody:result()}
    | {exception, woody_error:business_error()}
    | no_return().
register_operation(ServiceId, Operation, SlidingWindow, OpTimeLimit, PreAggrSize) ->
    do_register_operation(ServiceId,
                          Operation,
                          #fault_detector_ServiceConfig{
                             sliding_window = SlidingWindow,
                             operation_time_limit = OpTimeLimit,
                             pre_aggregation_size = PreAggrSize}).

%% PRIVATE

do_init_service(ServiceId, ServiceConfig) ->
    woody_client:call(
        {fd_proto_fault_detector_thrift, 'FaultDetector'},
        'InitService',
        [ServiceId, ServiceConfig],
        #{url => ?URL, event_handler => woody_event_handler_default}).

do_get_statistics(ServiceIds) ->
    woody_client:call(
        {fd_proto_fault_detector_thrift, 'FaultDetector'},
        'ServiceStatistics',
        ServiceIds,
        #{url => ?URL, event_handler => woody_event_handler_default}).

do_register_operation(ServiceId, Operation, ServiceConfig) ->
    woody_client:call(
        {fd_proto_fault_detector_thrift, 'FaultDetector'},
        'RegisterOperation',
        [ServiceId, Operation, ServiceConfig],
        #{url => ?URL, event_handler => woody_event_handler_default}).
