%%% Fault detector interaction

-module(hg_fault_detector_client).

-include_lib("fault_detector_proto/include/fd_proto_fault_detector_thrift.hrl").

-export([init_service/2]).
-export([get_statistics/1]).
-export([register_operation/3]).

-type service_id()      :: binary().

-type service_stats()   :: fd_proto_fault_detector_thrift:'ServiceStatistics'().
-type service_config()  :: fd_proto_fault_detector_thrift:'ServiceConfig'().
-type operation()       :: fd_proto_fault_detector_thrift:'Operation'().

-spec init_service(service_id(), service_config()) ->
    ok.
init_service(ServiceId, ServiceConfig) ->
    % woody_client:call(),
    ok.

-spec get_statistics(service_id()) ->
    ok.
get_statistics(ServiceId) ->
    % woody_client:call(),
    ok.

-spec register_operation(service_id(), operation(), service_config()) ->
    ok.
register_operation(ServiceId, Operation, ServiceConfig) ->
    % woody_client:call(),
    ok.
