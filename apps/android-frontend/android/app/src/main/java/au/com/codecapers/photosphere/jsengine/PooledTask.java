package au.com.codecapers.photosphere.jsengine;

//
// An immutable description of a single background task queued into the engine pool.
// It carries everything an engine needs to run the task and everything the plugin
// needs to route the result back to the WebView. `data` is kept as a JSON string so
// it crosses the JS bridge unchanged.
//
public final class PooledTask {

    //
    // Unique id for this task, generated in the JS frontend and echoed in every event.
    //
    public final String taskId;

    //
    // The task type name used by the embedded worker to look up the registered handler.
    //
    public final String type;

    //
    // The task input data, already serialised to a JSON string for the bridge.
    //
    public final String dataJson;

    //
    // The source tag grouping related tasks; cancellation is performed by source.
    //
    public final String source;

    //
    // How urgent the task is. The pool dispatches every interactive task before any background one,
    // so a tap the user is waiting on does not sit behind an import's backlog.
    //
    public final TaskPriority priority;

    //
    // Constructs a pooled task. All fields are required and final.
    //
    public PooledTask(String taskId, String type, String dataJson, String source, TaskPriority priority) {
        this.taskId = taskId;
        this.type = type;
        this.dataJson = dataJson;
        this.source = source;
        this.priority = priority;
    }
}
