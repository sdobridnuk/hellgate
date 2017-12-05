-ifndef(__hellgate_receipt_events__).
-define(__hellgate_receipt_events__, 42).

%%
%% Recurrent Payment Tools
%%

% Events

-define(created(ReceiptParams, Proxy),
    {created, #cashreg_proc_ReceiptCreated{
        receipt_params = ReceiptParams,
        proxy = Proxy
    }}
).

-define(registered(Receipt),
    {registered, #cashreg_proc_ReceiptRegistered{receipt = Receipt}}).

-define(failed(Failure),
    {failed, #cashreg_proc_ReceiptFailed{failure = Failure}}).

-define(session_changed(Payload),
    {session_changed, #cashreg_proc_ReceiptSessionChange{
        payload = Payload
    }}
).

%% Sessions

-define(session_started(),
    {session_started,
        #cashreg_proc_SessionStarted{}
    }
).
-define(session_finished(Result),
    {session_finished,
        #cashreg_proc_SessionFinished{result = Result}
    }
).
-define(session_suspended(Tag),
    {session_suspended,
        #cashreg_proc_SessionSuspended{tag = Tag}
    }
).
-define(proxy_st_changed(ProxySt),
    {session_proxy_state_changed,
        #cashreg_proc_SessionProxyStateChanged{proxy_state = ProxySt}
    }
).

-define(session_succeeded(),
    {succeeded, #cashreg_proc_SessionSucceeded{}}
).
-define(session_failed(Failure),
    {failed, #cashreg_proc_SessionFailed{failure = Failure}}
).

-endif.
