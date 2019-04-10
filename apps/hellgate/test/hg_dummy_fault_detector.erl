-module(hg_dummy_fault_detector).
-behaviour(hg_woody_wrapper).

-export([handle_function/3]).

-behaviour(hg_test_proxy).

-export([get_service_spec/0]).


-include_lib("fault_detector_proto/include/fd_proto_fault_detector_thrift.hrl").

-spec get_service_spec() ->
    hg_proto:service_spec().

get_service_spec() ->
    {"/test/proxy/fault_detector/dummy", {fd_proto_fault_detector_thrift, 'FaultDetector'}}.


-spec handle_function(woody:func(), woody:args(), hg_woody_wrapper:handler_opts()) ->
    term() | no_return().

handle_function('GetStatistics', _, _Options) -> [];
handle_function('RegisterOperation', _, _Options) -> [];
handle_function('InitService', _, _Options) -> [].
