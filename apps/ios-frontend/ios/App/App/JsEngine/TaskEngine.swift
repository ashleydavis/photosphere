import Foundation

//
// The abstraction the dispatcher drives. A TaskEngine runs one task at a time and
// reports its outcome through EngineCallbacks. The real implementation
// (JavaScriptCoreTaskEngine) owns a JSContext; tests supply a deterministic stub
// engine. The dispatcher depends ONLY on this protocol, never on JavaScriptCore,
// so the pool can be unit-tested with no real engine. This mirrors the Android
// `TaskEngine` interface.
//
protocol TaskEngine: AnyObject {

    //
    // Runs a single task. Implementations must call exactly one of the callback's
    // onTaskSucceeded / onTaskFailed terminal methods when the task completes, and may
    // call onTaskMessage any number of times before then. Implementations decide their
    // own threading; the pool calls this on the engine's dedicated serial queue.
    //
    func runTask(_ task: PooledTask, callbacks: EngineCallbacks)

    //
    // Disposes the engine and releases its underlying JS context. Called once during
    // pool shutdown. After dispose the engine must not be reused.
    //
    func dispose()
}
