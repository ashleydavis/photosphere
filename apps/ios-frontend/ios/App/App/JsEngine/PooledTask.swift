import Foundation

//
// An immutable description of a single background task queued into the engine pool.
// It carries everything an engine needs to run the task and everything the plugin
// needs to route the result back to the WebView. `dataJson` is kept as a JSON string
// so the task input crosses the JS bridge unchanged. This mirrors the Android
// `PooledTask` so both platforms share the same dispatcher contract.
//
struct PooledTask {

    //
    // Unique id for this task, generated in the JS frontend and echoed in every event.
    //
    let taskId: String

    //
    // The task type name used by the embedded worker to look up the registered handler.
    //
    let type: String

    //
    // The task input data, already serialised to a JSON string for the bridge.
    //
    let dataJson: String

    //
    // The source tag grouping related tasks; cancellation is performed by source.
    //
    let source: String

    //
    // How urgent the task is, or nil when nothing named one. The pool dispatches every interactive
    // task before any background one, so a tap the user is waiting on does not sit behind an
    // import's backlog. Nil means the pool decides: a child runs at its parent's priority, and
    // anything else at the default.
    //
    let priority: TaskPriority?

    //
    // The priority the task actually runs at once the pool has decided.
    //
    var effectivePriority: TaskPriority {
        return priority ?? TaskPriority.defaultPriority
    }
}
