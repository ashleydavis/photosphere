import Foundation

//
// The callback surface an engine uses to report back into the pool/plugin while and
// after running a task. The engine never depends on Capacitor or JavaScriptCore through
// this seam: it reports completion and streamed messages through this protocol, which the
// pool and tests implement. This keeps the dispatcher and engines independently testable,
// mirroring the Android `EngineCallbacks` interface.
//
protocol EngineCallbacks: AnyObject {

    //
    // Called exactly once when a task finishes successfully. `outputsJson` is the JSON
    // string the handler returned (or "null" when the handler returned nothing). The pool
    // turns this into a "succeeded" taskCompleted event for the WebView.
    //
    func onTaskSucceeded(_ task: PooledTask, outputsJson: String)

    //
    // Called exactly once when a task fails (including the NOT IMPLEMENTED case).
    // `errorMessage` is the human-readable error text echoed into the taskCompleted event
    // as a "failed" result.
    //
    func onTaskFailed(_ task: PooledTask, errorMessage: String)

    //
    // Called whenever the running handler streams a progress message via
    // host.sendMessage(taskId, messageJson). `messageJson` is the raw JSON string the
    // handler produced; the pool forwards it as a taskMessage event.
    //
    func onTaskMessage(_ task: PooledTask, messageJson: String)
}
