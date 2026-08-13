package au.com.codecapers.photosphere.jsengine;

import java.util.ArrayDeque;
import java.util.Deque;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Iterator;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

//
// The engine pool and dispatcher. This is the heart of the mobile background-task
// system and is written as plain, lock-guarded Java so it can be unit-tested with stub
// engines on a plain JVM (no QuickJS, no device). It owns:
//   - a pending-task FIFO,
//   - a fixed set of TaskEngine slots (one per native worker thread),
//   - the set of idle (available) engine slots,
//   - a running-task map (taskId -> the engine running it),
//   - a cancelled-source set with per-task atomic cancelled flags,
//   - the single pool-owned sessionId shared by every engine.
// All shared structures are guarded by a single lock. The cancelled flags are read by
// host.isCancelled WITHOUT the lock (see CancellationState), so a running task can poll
// cancellation cheaply mid-task.
//
public final class EnginePool {

    //
    // Build-time pool size constant: the single source of truth for how many engine
    // threads run in parallel. A value of 1 degrades gracefully to strictly serial execution
    // (one task finishes before the next starts). Change this here only; nothing else reads
    // or writes the pool size. Keep it in step with POOL_SIZE in the iOS EnginePool.swift.
    //
    // Five, because that is what the deepest chain of tasks needs plus one to spare. Automatic
    // import is the deepest: the asset server holds a slot for the life of the app, auto-import
    // holds one for as long as the setting is on, the import-assets task it queues holds a third,
    // and the hash-file and upload-asset tasks that import queues in turn need a fourth. At four
    // that chain fits exactly and nothing else can run beside it, so a sync waits and only one file
    // is hashed at a time. The fifth is that headroom.
    //
    // A task that waits on a task it queued must never be able to use the last free slot, because
    // both then wait forever and it looks from outside exactly like a slow import: the setting is
    // on, the task is running, and the counts stay at zero. That is not theoretical; it is what
    // this pool did at three.
    //
    public static final int POOL_SIZE = 5;

    //
    // Factory that produces one TaskEngine per pool slot. Abstracted so production wires
    // the QuickJS engine and tests wire a deterministic stub engine.
    //
    public interface EngineFactory {

        //
        // Creates a single engine for the given zero-based slot index, handed the pool-owned
        // sessionId and shared cancellation state so the engine's host bridge can use them.
        // The pool calls this POOL_SIZE times during construction, passing values it has
        // already generated, so there is no construction-ordering cycle.
        //
        TaskEngine createEngine(int slotIndex, String sessionId, CancellationState cancellationState);
    }

    //
    // The single lock guarding every shared structure below. Held only for short,
    // non-reentrant critical sections; never held while calling into an engine.
    //
    private final Object lock = new Object();

    //
    // Pending tasks waiting for a free engine, in strict FIFO order.
    //
    private final Deque<PooledTask> pendingQueue = new ArrayDeque<>();

    //
    // Idle engines available to pick up the next pending task.
    //
    private final Deque<TaskEngine> idleEngines = new ArrayDeque<>();

    //
    // All engines owned by the pool, indexed by slot, for teardown.
    //
    private final TaskEngine[] allEngines;

    //
    // Map of in-flight taskId -> the engine currently running it.
    //
    private final Map<String, TaskEngine> runningByTaskId = new HashMap<>();

    //
    // Map of in-flight taskId -> the PooledTask, so a freed engine can clean up state.
    //
    private final Map<String, PooledTask> runningTasksById = new HashMap<>();

    //
    // Map of child taskId -> the engine that spawned it. A child task's outcome is routed back to
    // its origin engine (so an orchestrator handler awaiting it resolves) instead of to the WebView.
    // Root tasks queued from the WebView are absent from this map and keep going to the poolListener.
    //
    private final Map<String, TaskEngine> childOriginByTaskId = new HashMap<>();

    //
    // The set of cancelled source tags. A task whose source is in this set is considered
    // cancelled and is dropped from pending / observed as cancelled while running.
    //
    private final Set<String> cancelledSources = new HashSet<>();

    //
    // Shared cancellation state holding per-task atomic flags, read lock-free by
    // host.isCancelled from inside a running task.
    //
    private final CancellationState cancellationState = new CancellationState();

    //
    // The callbacks the pool exposes to engines. Bound once, reused for every task.
    //
    private final EngineCallbacks engineCallbacks;

    //
    // Listener notified of completions and messages, so the plugin can forward them to the
    // WebView. Separate from EngineCallbacks so the plugin layer stays decoupled.
    //
    private final PoolListener poolListener;

    //
    // The single pool-owned session id, generated once at construction and shared by every
    // engine's runTask context. Mirrors the desktop main process generating it once.
    //
    private final String sessionId;

    //
    // True once shutdown has begun; blocks any further dispatch.
    //
    private boolean shuttingDown = false;

    //
    // The listener the pool reports task outcomes to (implemented by the plugin).
    //
    public interface PoolListener {

        //
        // A task finished successfully; outputsJson is the handler's returned value as JSON.
        //
        void onTaskSucceeded(PooledTask task, String outputsJson);

        //
        // A task failed; errorMessage is the error text.
        //
        void onTaskFailed(PooledTask task, String errorMessage);

        //
        // A running task streamed a progress message (raw JSON string).
        //
        void onTaskMessage(PooledTask task, String messageJson);
    }

    //
    // Constructs the pool at the default POOL_SIZE. Production always uses this constructor, so
    // POOL_SIZE remains the single source of truth for how many engines run in production.
    //
    public EnginePool(EngineFactory engineFactory, PoolListener poolListener) {
        this(engineFactory, poolListener, POOL_SIZE);
    }

    //
    // Constructs the pool at an explicit size, generates the shared sessionId, creates `size`
    // engines via the factory, and marks them all idle. The explicit-size constructor exists so
    // the dispatcher tests can exercise a size-1 pool (serial execution) and small pools to assert
    // the concurrency cap, without changing the production POOL_SIZE constant. Dispatch is driven
    // entirely by addTask and by engines freeing as tasks complete.
    //
    public EnginePool(EngineFactory engineFactory, PoolListener poolListener, int size) {
        if (size < 1) {
            throw new IllegalArgumentException("EnginePool size must be at least 1.");
        }

        this.poolListener = poolListener;
        this.sessionId = UUID.randomUUID().toString();
        this.allEngines = new TaskEngine[size];
        this.engineCallbacks = new PoolEngineCallbacks();

        for (int slotIndex = 0; slotIndex < size; slotIndex++) {
            TaskEngine engine = engineFactory.createEngine(slotIndex, this.sessionId, this.cancellationState);
            this.allEngines[slotIndex] = engine;
            this.idleEngines.addLast(engine);
        }
    }

    //
    // Returns the single pool-owned session id shared across all engines.
    //
    public String getSessionId() {
        return sessionId;
    }

    //
    // Returns the shared cancellation state so the host bridge can poll it lock-free.
    //
    public CancellationState getCancellationState() {
        return cancellationState;
    }

    //
    // Enqueues a task and immediately tries to dispatch it to an idle engine. Called from the
    // plugin's addTask. Thread-safe.
    //
    public void addTask(PooledTask task) {
        synchronized (lock) {
            if (shuttingDown) {
                return;
            }

            // Re-arm the source. Cancelling a source cancels the work in flight at that moment and
            // nothing more; it must not disable the source for future work. A task arriving here is a
            // fresh, deliberate request from the WebView, not a straggler of the cancelled batch, so
            // it clears the cancellation rather than being dropped by it.
            //
            // queueChildTask deliberately does NOT do this, and the asymmetry is the point: children
            // are spawned from inside a running handler, so a batch being cancelled right now can
            // still be producing them and they must still be dropped. Clearing in both places would
            // break cancellation outright.
            //
            // Without this, cancelling a source poisoned it for the life of the app: every later task
            // under that name was discarded before dispatch, with nothing rejected and nothing logged.
            // A second replication of the same database, or a second browse of an S3 bucket, simply
            // did nothing.
            cancelledSources.remove(task.source);

            cancellationState.register(task.taskId, false);
            pendingQueue.addLast(task);
            dispatchNextLocked();
        }
    }

    //
    // Enqueues a child task spawned by a running handler and tries to dispatch it, tagging it with
    // the origin engine (looked up from the parent task id) so its outcome routes back to that
    // engine. Mirrors the Electron main process handling a worker's "queue-task" message. If the
    // parent is no longer running, or the child's source was already cancelled, the child is
    // dropped. Thread-safe.
    //
    public void queueChildTask(String parentTaskId, PooledTask child) {
        synchronized (lock) {
            if (shuttingDown) {
                return;
            }

            // Kept, unlike addTask, which clears the source instead. A child comes from a handler that
            // is already running, so a batch being cancelled right now can still be producing children
            // and they must be dropped. This check is the reason the set exists.
            if (cancelledSources.contains(child.source)) {
                return;
            }

            TaskEngine origin = runningByTaskId.get(parentTaskId);
            if (origin == null) {
                // The parent already finished; there is nothing to deliver the child's result to.
                return;
            }

            childOriginByTaskId.put(child.taskId, origin);
            cancellationState.register(child.taskId, false);
            pendingQueue.addLast(child);
            dispatchNextLocked();
        }
    }

    //
    // Cancels all tasks for a source: records the source, marks every matching task's atomic
    // flag cancelled, and drops still-pending matching tasks from the FIFO so they never
    // dispatch. Running tasks observe cancellation on their next host.isCancelled poll.
    // Thread-safe.
    //
    public void cancelTasks(String source) {
        synchronized (lock) {
            cancelledSources.add(source);

            // Mark running tasks for this source as cancelled via their atomic flags.
            for (PooledTask runningTask : runningTasksById.values()) {
                if (runningTask.source.equals(source)) {
                    cancellationState.setCancelled(runningTask.taskId);
                }
            }

            // Drop still-pending tasks for this source so they never dispatch.
            Iterator<PooledTask> iterator = pendingQueue.iterator();
            while (iterator.hasNext()) {
                PooledTask pendingTask = iterator.next();
                if (pendingTask.source.equals(source)) {
                    cancellationState.setCancelled(pendingTask.taskId);
                    cancellationState.unregister(pendingTask.taskId);
                    childOriginByTaskId.remove(pendingTask.taskId);
                    iterator.remove();
                }
            }
        }
    }

    //
    // Tears the pool down: stops further dispatch, abandons the pending FIFO, disposes every
    // engine, and clears all shared structures. Running engines are signalled via their
    // cancelled flags and disposed; the engine implementation is responsible for stopping its
    // context. Thread-safe and idempotent.
    //
    public void shutdown() {
        TaskEngine[] enginesToDispose;

        synchronized (lock) {
            if (shuttingDown) {
                return;
            }
            shuttingDown = true;

            // Signal any running task to stop on its next cancellation poll.
            for (String runningTaskId : runningByTaskId.keySet()) {
                cancellationState.setCancelled(runningTaskId);
            }

            pendingQueue.clear();
            idleEngines.clear();
            runningByTaskId.clear();
            runningTasksById.clear();
            childOriginByTaskId.clear();
            cancelledSources.clear();
            cancellationState.clear();

            enginesToDispose = allEngines.clone();
        }

        // Dispose engines outside the lock: dispose may block on the engine thread.
        for (TaskEngine engine : enginesToDispose) {
            if (engine != null) {
                engine.dispose();
            }
        }
    }

    //
    // Assigns the next pending task to the next idle engine, if both exist. Must be called
    // with the lock held. Loops so that as long as there is an idle engine and a pending
    // task, work is dispatched (covers the case where several engines are idle at once).
    //
    private void dispatchNextLocked() {
        while (!pendingQueue.isEmpty() && !idleEngines.isEmpty() && !shuttingDown) {
            PooledTask nextTask = pendingQueue.pollFirst();

            // Skip (and drop) tasks whose source was cancelled while pending.
            if (cancelledSources.contains(nextTask.source)) {
                cancellationState.unregister(nextTask.taskId);
                continue;
            }

            TaskEngine engine = idleEngines.pollFirst();
            runningByTaskId.put(nextTask.taskId, engine);
            runningTasksById.put(nextTask.taskId, nextTask);

            // Run outside the lock so the engine thread does not contend with the dispatcher.
            // The engine implementation hands work to its own thread, so runTask returns
            // promptly; the terminal callback drives the next dispatch.
            engine.runTask(nextTask, engineCallbacks);
        }
    }

    //
    // Marks the engine that ran the given task as idle again, removes the task from the
    // running maps, and dispatches the next pending task. Must be called with the lock held.
    //
    private void freeEngineLocked(PooledTask task) {
        TaskEngine engine = runningByTaskId.remove(task.taskId);
        runningTasksById.remove(task.taskId);
        cancellationState.unregister(task.taskId);

        if (engine != null && !shuttingDown) {
            idleEngines.addLast(engine);
        }

        dispatchNextLocked();
    }

    //
    // The EngineCallbacks the pool hands every engine. On a terminal callback it frees the
    // engine (under the lock) and then forwards the outcome OUTSIDE the lock, so the hand-off
    // never runs while the dispatcher lock is held. A child task's outcome is routed back to the
    // engine that spawned it (via deliverChildEvent); a root task's outcome goes to the plugin
    // listener (the WebView), exactly as Electron keeps child-task results off the renderer.
    //
    private final class PoolEngineCallbacks implements EngineCallbacks {

        //
        // Routes a streamed progress message to the plugin listener (the WebView), for both root and
        // child tasks. This matches Electron, where a worker's task-message reaches the client/UI, not
        // the orchestrator that spawned it: the import UI consumes import-pending (sent by the
        // upload-asset subtask) and import-success (sent by the import-assets root task). Only child
        // COMPLETIONS route back to the origin engine so the orchestrator's awaitTask resolves.
        //
        @Override
        public void onTaskMessage(PooledTask task, String messageJson) {
            poolListener.onTaskMessage(task, messageJson);
        }

        //
        // Frees the engine and routes the success result to the origin engine (child) or the
        // plugin listener (root).
        //
        @Override
        public void onTaskSucceeded(PooledTask task, String outputsJson) {
            TaskEngine origin;
            synchronized (lock) {
                origin = childOriginByTaskId.remove(task.taskId);
                freeEngineLocked(task);
            }

            if (origin != null) {
                origin.deliverChildEvent(buildChildCompletedEvent(task, true, null, outputsJson), true);
            }
            else {
                poolListener.onTaskSucceeded(task, outputsJson);
            }
        }

        //
        // Frees the engine and routes the failure result to the origin engine (child) or the
        // plugin listener (root).
        //
        @Override
        public void onTaskFailed(PooledTask task, String errorMessage) {
            TaskEngine origin;
            synchronized (lock) {
                origin = childOriginByTaskId.remove(task.taskId);
                freeEngineLocked(task);
            }

            if (origin != null) {
                origin.deliverChildEvent(buildChildCompletedEvent(task, false, errorMessage, null), true);
            }
            else {
                poolListener.onTaskFailed(task, errorMessage);
            }
        }

        //
        // Queues a child task on the pool's pending FIFO, tagged with its parent so the child's
        // outcome routes back to the parent's engine.
        //
        @Override
        public void queueChildTask(String parentTaskId, String childTaskId, String type, String dataJson, String source) {
            EnginePool.this.queueChildTask(parentTaskId, new PooledTask(childTaskId, type, dataJson, source));
        }
    }

    //
    // Builds the JSON for a child completion event delivered into the origin engine's
    // globalThis.__childEvent. The already-valid JSON fragments (the child's inputs dataJson and
    // its outputs) are embedded raw; the plain string fields are escaped. This deliberately avoids
    // org.json so the pool stays unit-testable on a plain JVM (the Android org.json stub throws).
    //
    private static String buildChildCompletedEvent(PooledTask task, boolean succeeded, String errorMessage, String outputsJson) {
        StringBuilder builder = new StringBuilder();
        builder.append("{\"kind\":\"completed\",\"result\":{");
        builder.append("\"taskId\":\"").append(jsonEscape(task.taskId)).append("\",");
        builder.append("\"status\":\"").append(succeeded ? "succeeded" : "failed").append("\",");
        builder.append("\"type\":\"").append(jsonEscape(task.type)).append("\",");
        builder.append("\"inputs\":").append(task.dataJson == null ? "null" : task.dataJson);

        if (succeeded) {
            builder.append(",\"outputs\":").append(outputsJson == null ? "null" : outputsJson);
        }
        else {
            builder.append(",\"errorMessage\":\"").append(jsonEscape(errorMessage == null ? "Unknown error" : errorMessage)).append("\"");
        }

        builder.append("}}");
        return builder.toString();
    }

    //
    // Escapes a plain string for embedding inside a JSON string literal. Covers the characters that
    // must be escaped per the JSON spec: backslash, double-quote, and the C0 control range.
    //
    private static String jsonEscape(String value) {
        StringBuilder builder = new StringBuilder(value.length() + 8);
        for (int index = 0; index < value.length(); index++) {
            char character = value.charAt(index);
            switch (character) {
                case '\\':
                    builder.append("\\\\");
                    break;
                case '"':
                    builder.append("\\\"");
                    break;
                case '\n':
                    builder.append("\\n");
                    break;
                case '\r':
                    builder.append("\\r");
                    break;
                case '\t':
                    builder.append("\\t");
                    break;
                default:
                    if (character < 0x20) {
                        builder.append(String.format("\\u%04x", (int) character));
                    }
                    else {
                        builder.append(character);
                    }
                    break;
            }
        }
        return builder.toString();
    }
}
