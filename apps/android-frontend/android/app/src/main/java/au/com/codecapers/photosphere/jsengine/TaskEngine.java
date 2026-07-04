package au.com.codecapers.photosphere.jsengine;

//
// The abstraction the dispatcher drives. A TaskEngine runs one task at a time and
// reports its outcome through EngineCallbacks. The real implementation
// (QuickJsTaskEngine) owns a QuickJS context; tests supply a deterministic stub
// engine. The dispatcher depends ONLY on this interface, never on QuickJS/Quack,
// so the pool can be unit-tested on a plain JVM with no native engine.
//
public interface TaskEngine {

    //
    // Runs a single task. Implementations must call exactly one of the callback's
    // onTaskSucceeded / onTaskFailed terminal methods when the task completes, and may
    // call onTaskMessage any number of times before then. Implementations decide their
    // own threading; the pool calls this on the engine's dedicated worker thread.
    //
    void runTask(PooledTask task, EngineCallbacks callbacks);

    //
    // Delivers a child-task event (a completion or a streamed message) from the pool back into
    // this engine, so an orchestrator handler running here that is awaiting its subtasks can
    // resolve. `eventJson` is the JSON the JS side's globalThis.__childEvent expects. `terminal`
    // is true for a completion (so the engine can stop treating that child as outstanding) and
    // false for a streamed message. Thread-safe: called from other engines' worker threads.
    //
    void deliverChildEvent(String eventJson, boolean terminal);

    //
    // Disposes the engine and releases its underlying JS context. Called once during
    // pool shutdown. After dispose the engine must not be reused.
    //
    void dispose();
}
