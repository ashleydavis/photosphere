package au.com.codecapers.photosphere.jsengine;

//
// The callback surface an engine uses to report back into the pool/plugin while and
// after running a task. The engine never depends on Capacitor or QuickJS directly:
// it reports completion and streamed messages through this interface, which the pool
// and tests implement. This keeps the dispatcher and engines independently testable.
//
public interface EngineCallbacks {

    //
    // Called exactly once when a task finishes successfully. `outputsJson` is the JSON
    // string the handler returned (or "null" when the handler returned nothing). The pool
    // turns this into a "succeeded" taskCompleted event for the WebView.
    //
    void onTaskSucceeded(PooledTask task, String outputsJson);

    //
    // Called exactly once when a task fails (including the NOT IMPLEMENTED case).
    // `errorMessage` is the human-readable error text echoed into the taskCompleted event
    // as a "failed" result.
    //
    void onTaskFailed(PooledTask task, String errorMessage);

    //
    // Called whenever the running handler streams a progress message via
    // host.sendMessage(taskId, messageJson). `messageJson` is the raw JSON string the
    // handler produced; the pool forwards it as a taskMessage event.
    //
    void onTaskMessage(PooledTask task, String messageJson);

    //
    // Called when a running handler enqueues a child task via host.queueTask. The pool queues
    // the child on the pending FIFO for its priority (the mobile "main-thread queue") and, when the
    // child finishes, routes its outcome back to the engine identified by `parentTaskId` rather than
    // to the WebView. This mirrors Electron routing a worker's "queue-task" message to the
    // main-process pool. `priorityWireName` is null when the child named no priority, which means it
    // runs at its parent's.
    //
    void queueChildTask(String parentTaskId, String childTaskId, String type, String dataJson, String source, String priorityWireName);
}
