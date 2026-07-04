package au.com.codecapers.photosphere.jsengine;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.atomic.AtomicInteger;

//
// A deterministic, controllable stub TaskEngine for the dispatcher unit tests. It does NOT run
// any JS. Instead it records the task it was handed and waits for the test to explicitly signal
// completion (succeed / fail), so the test drives the exact timing of engine frees and can
// assert ordering, idle-slot assignment, reassignment, and concurrency caps. It also tracks how
// many tasks are running concurrently across all stub engines via a shared counter, so a test
// can assert the pool never exceeds POOL_SIZE.
//
public final class StubEngine implements TaskEngine {

    //
    // The shared counter of currently-running stub engines across the whole pool, used to assert
    // the concurrency cap. Incremented when a task starts on any stub engine, decremented when it
    // completes.
    //
    private final AtomicInteger sharedRunningCount;

    //
    // The high-water mark of concurrent running engines observed, used to assert the cap.
    //
    private final AtomicInteger sharedMaxConcurrent;

    //
    // The task currently assigned to this engine, or null if idle.
    //
    private PooledTask currentTask;

    //
    // The callbacks for the current task, used by the test to signal completion.
    //
    private EngineCallbacks currentCallbacks;

    //
    // True once dispose has been called.
    //
    private boolean disposed = false;

    //
    // The JSON of every child event the pool delivered into this engine, in order. Lets a test
    // assert a child task's outcome was routed back to the engine that spawned it.
    //
    public final List<String> deliveredChildEvents = new ArrayList<>();

    //
    // Whether each delivered child event was terminal (a completion) or a streamed message, in order.
    //
    public final List<Boolean> deliveredChildTerminals = new ArrayList<>();

    //
    // Constructs a stub engine sharing the pool-wide concurrency counters.
    //
    public StubEngine(AtomicInteger sharedRunningCount, AtomicInteger sharedMaxConcurrent) {
        this.sharedRunningCount = sharedRunningCount;
        this.sharedMaxConcurrent = sharedMaxConcurrent;
    }

    //
    // Records the task and callbacks and bumps the shared concurrency counters, but does NOT
    // complete the task. The test completes it later via succeed()/fail().
    //
    @Override
    public void runTask(PooledTask task, EngineCallbacks callbacks) {
        this.currentTask = task;
        this.currentCallbacks = callbacks;

        int running = sharedRunningCount.incrementAndGet();
        sharedMaxConcurrent.accumulateAndGet(running, Math::max);
    }

    //
    // Returns the task currently assigned to this engine, or null if idle.
    //
    public PooledTask getCurrentTask() {
        return currentTask;
    }

    //
    // True if this engine currently has a task assigned (is running).
    //
    public boolean isRunning() {
        return currentTask != null;
    }

    //
    // True once the engine has been disposed.
    //
    public boolean isDisposed() {
        return disposed;
    }

    //
    // Completes the current task successfully, decrements the concurrency counter, and returns
    // the engine to idle. Drives the pool to dispatch the next pending task.
    //
    public void succeed(String outputsJson) {
        PooledTask task = currentTask;
        EngineCallbacks callbacks = currentCallbacks;
        clearCurrent();
        sharedRunningCount.decrementAndGet();
        callbacks.onTaskSucceeded(task, outputsJson);
    }

    //
    // Completes the current task as a failure, decrements the concurrency counter, and returns
    // the engine to idle.
    //
    public void fail(String errorMessage) {
        PooledTask task = currentTask;
        EngineCallbacks callbacks = currentCallbacks;
        clearCurrent();
        sharedRunningCount.decrementAndGet();
        callbacks.onTaskFailed(task, errorMessage);
    }

    //
    // Emits a streamed message for the current task without completing it.
    //
    public void emitMessage(String messageJson) {
        currentCallbacks.onTaskMessage(currentTask, messageJson);
    }

    //
    // Clears the current task/callbacks so the engine reads as idle again.
    //
    private void clearCurrent() {
        this.currentTask = null;
        this.currentCallbacks = null;
    }

    //
    // Records a child event the pool routed back into this engine.
    //
    @Override
    public void deliverChildEvent(String eventJson, boolean terminal) {
        deliveredChildEvents.add(eventJson);
        deliveredChildTerminals.add(terminal);
    }

    //
    // Marks the engine disposed.
    //
    @Override
    public void dispose() {
        this.disposed = true;
    }
}
