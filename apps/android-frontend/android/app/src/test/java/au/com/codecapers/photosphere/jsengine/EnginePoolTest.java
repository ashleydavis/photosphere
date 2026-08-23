package au.com.codecapers.photosphere.jsengine;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.concurrent.atomic.AtomicInteger;

//
// Plain-JVM unit tests for the engine pool dispatcher. They drive the dispatcher directly with
// deterministic StubEngines (no QuickJS, no device), completing tasks on the test thread so the
// timing of every engine free is controlled. This covers FIFO ordering, idle-slot assignment,
// reassignment on free, the concurrency cap, size-1 serial execution, and the two distinct
// cancellation cases (pending vs running).
//
public final class EnginePoolTest {

    //
    // Shared counter of currently-running stub engines, used to assert the concurrency cap.
    //
    private final AtomicInteger runningCount = new AtomicInteger(0);

    //
    // High-water mark of concurrent running engines observed across a test.
    //
    private final AtomicInteger maxConcurrent = new AtomicInteger(0);

    //
    // The stub engines created by the factory, in slot order, so a test can inspect/complete them.
    //
    private final List<StubEngine> engines = new ArrayList<>();

    //
    // Builds a pool of the given size whose factory records each StubEngine it creates.
    //
    private EnginePool newPool(RecordingPoolListener listener, int size) {
        EnginePool.EngineFactory factory = (slotIndex, sessionId, cancellationState) -> {
            StubEngine engine = new StubEngine(runningCount, maxConcurrent);
            engines.add(engine);
            return engine;
        };
        return new EnginePool(factory, listener, size);
    }

    //
    // Builds a task with the given id and source, at no particular priority (so it runs at the
    // default). Data is irrelevant to the dispatcher.
    //
    private PooledTask task(String taskId, String source) {
        return new PooledTask(taskId, "test-type", "{}", source, null);
    }

    //
    // Builds a task with the given id, source and priority.
    //
    private PooledTask task(String taskId, String source, TaskPriority priority) {
        return new PooledTask(taskId, "test-type", "{}", source, priority);
    }

    //
    // Returns the stub engine currently running the given task id, or null if none is.
    //
    private StubEngine engineRunning(String taskId) {
        for (StubEngine engine : engines) {
            if (engine.isRunning() && engine.getCurrentTask().taskId.equals(taskId)) {
                return engine;
            }
        }
        return null;
    }

    //
    // Priority: an interactive task added after background tasks are already waiting is dispatched
    // before all of them. This is the tap that must not sit behind an import's backlog.
    //
    @Test
    public void interactiveTaskIsDispatchedBeforeWaitingBackgroundTasks() {
        RecordingPoolListener listener = new RecordingPoolListener();
        EnginePool pool = newPool(listener, 1);

        pool.addTask(task("running", "src", TaskPriority.BACKGROUND));
        pool.addTask(task("background-1", "src", TaskPriority.BACKGROUND));
        pool.addTask(task("background-2", "src", TaskPriority.BACKGROUND));
        pool.addTask(task("interactive", "src", TaskPriority.INTERACTIVE));

        // The first task was already running when the interactive one arrived, so it finishes first.
        engineRunning("running").succeed("1");

        // The engine it freed goes to the interactive task, not to the background tasks that have
        // been waiting longer.
        assertNotNull(engineRunning("interactive"));
        assertNull(engineRunning("background-1"));

        engineRunning("interactive").succeed("2");
        engineRunning("background-1").succeed("3");
        engineRunning("background-2").succeed("4");

        assertEquals(Arrays.asList("running", "interactive", "background-1", "background-2"), listener.succeededTaskIds);
    }

    //
    // Priority: there is one queue. An interactive task joins the head, so a later tap runs before an
    // earlier one still waiting; a background task joins the end, so background work keeps its
    // arrival order.
    //
    @Test
    public void interactiveTasksJoinTheHeadAndBackgroundTasksTheEnd() {
        RecordingPoolListener listener = new RecordingPoolListener();
        EnginePool pool = newPool(listener, 1);

        pool.addTask(task("running", "src", TaskPriority.BACKGROUND));
        pool.addTask(task("background-1", "src", TaskPriority.BACKGROUND));
        pool.addTask(task("interactive-1", "src", TaskPriority.INTERACTIVE));
        pool.addTask(task("background-2", "src", TaskPriority.BACKGROUND));
        pool.addTask(task("interactive-2", "src", TaskPriority.INTERACTIVE));

        engineRunning("running").succeed("1");
        engineRunning("interactive-2").succeed("2");
        engineRunning("interactive-1").succeed("3");
        engineRunning("background-1").succeed("4");
        engineRunning("background-2").succeed("5");

        assertEquals(
            Arrays.asList("running", "interactive-2", "interactive-1", "background-1", "background-2"),
            listener.succeededTaskIds);
    }

    //
    // Priority: a task that names no priority runs in the background, so nothing gets in front of
    // the user by accident.
    //
    @Test
    public void aTaskThatNamesNoPriorityRunsInTheBackground() {
        RecordingPoolListener listener = new RecordingPoolListener();
        EnginePool pool = newPool(listener, 1);

        pool.addTask(task("running", "src", TaskPriority.BACKGROUND));
        pool.addTask(task("unspecified", "src", null));
        pool.addTask(task("interactive", "src", TaskPriority.INTERACTIVE));

        engineRunning("running").succeed("1");

        assertNotNull(engineRunning("interactive"));
        assertNull(engineRunning("unspecified"));
    }

    //
    // Priority: a child task that names no priority runs at its parent's, so the hash and upload
    // tasks an import queues can never overtake a tap.
    //
    @Test
    public void aChildInheritsItsParentsPriority() {
        RecordingPoolListener listener = new RecordingPoolListener();
        EnginePool pool = newPool(listener, 2);

        // A background parent and an interactive parent, each holding an engine.
        pool.addTask(task("background-parent", "src", TaskPriority.BACKGROUND));
        pool.addTask(task("interactive-parent", "src", TaskPriority.INTERACTIVE));

        // Both queue a child that names no priority. Neither can run yet: both engines are held.
        pool.queueChildTask("background-parent", task("background-child", "src", null));
        pool.queueChildTask("interactive-parent", task("interactive-child", "src", null));

        assertNull(engineRunning("background-child"));
        assertNull(engineRunning("interactive-child"));

        // One engine frees. It must go to the interactive parent's child, even though the background
        // parent's child was queued first.
        engineRunning("background-parent").succeed("1");

        assertNotNull(engineRunning("interactive-child"));
        assertNull(engineRunning("background-child"));
    }

    //
    // Priority: a child that names a priority of its own keeps it, which is how long-running work an
    // interactive task only kicks off opts back down to the background.
    //
    @Test
    public void aChildThatNamesAPriorityKeepsIt() {
        RecordingPoolListener listener = new RecordingPoolListener();
        EnginePool pool = newPool(listener, 2);

        pool.addTask(task("interactive-parent", "src", TaskPriority.INTERACTIVE));
        pool.addTask(task("blocker", "src", TaskPriority.BACKGROUND));

        // The interactive parent queues a child that asks to be background, and a second parent's
        // interactive task is queued behind it.
        pool.queueChildTask("interactive-parent", task("demoted-child", "src", TaskPriority.BACKGROUND));
        pool.addTask(task("interactive", "src", TaskPriority.INTERACTIVE));

        engineRunning("blocker").succeed("1");

        // The freed engine goes to the interactive task, not to the child that asked for background.
        assertNotNull(engineRunning("interactive"));
        assertNull(engineRunning("demoted-child"));
    }

    //
    // FIFO ordering: with a size-1 pool, four tasks added in order must run and complete in that
    // exact order, one strictly after another.
    //
    @Test
    public void pendingTasksRunInFifoOrder() {
        RecordingPoolListener listener = new RecordingPoolListener();
        EnginePool pool = newPool(listener, 1);

        pool.addTask(task("a", "src"));
        pool.addTask(task("b", "src"));
        pool.addTask(task("c", "src"));
        pool.addTask(task("d", "src"));

        // Only the first task runs at first; the rest are pending.
        assertNotNull(engineRunning("a"));
        assertNull(engineRunning("b"));

        // Complete each in turn; the next pending must start each time.
        engineRunning("a").succeed("1");
        engineRunning("b").succeed("2");
        engineRunning("c").succeed("3");
        engineRunning("d").succeed("4");

        assertEquals(Arrays.asList("a", "b", "c", "d"), listener.succeededTaskIds);
    }

    //
    // Idle-slot assignment: with several idle engines, each newly added task goes straight to an
    // idle engine and runs immediately (true parallelism up to the pool size).
    //
    @Test
    public void tasksAssignToIdleEngines() {
        RecordingPoolListener listener = new RecordingPoolListener();
        EnginePool pool = newPool(listener, 3);

        pool.addTask(task("a", "src"));
        pool.addTask(task("b", "src"));
        pool.addTask(task("c", "src"));

        // All three run at once because there are three idle engines.
        assertNotNull(engineRunning("a"));
        assertNotNull(engineRunning("b"));
        assertNotNull(engineRunning("c"));
        assertEquals(3, runningCount.get());
    }

    //
    // Reassignment on free: when a running engine frees, the next pending task is dispatched to it.
    //
    @Test
    public void engineReassignedWhenFreed() {
        RecordingPoolListener listener = new RecordingPoolListener();
        EnginePool pool = newPool(listener, 1);

        pool.addTask(task("a", "src"));
        pool.addTask(task("b", "src"));

        StubEngine engineForA = engineRunning("a");
        assertNotNull(engineForA);
        assertNull(engineRunning("b"));

        // Freeing the engine must hand it task b.
        engineForA.succeed("done");
        assertNotNull(engineRunning("b"));
        assertEquals(Arrays.asList("a"), listener.succeededTaskIds);
    }

    //
    // Concurrency cap: with more tasks than engines, no more than POOL_SIZE engines ever run at
    // once. Here POOL_SIZE under test is 2, and six tasks are dispatched.
    //
    @Test
    public void neverExceedsPoolSize() {
        RecordingPoolListener listener = new RecordingPoolListener();
        EnginePool pool = newPool(listener, 2);

        for (int index = 0; index < 6; index++) {
            pool.addTask(task("t" + index, "src"));
        }

        // At most two run at a time; drain them, completing whatever is running.
        int completed = 0;
        while (completed < 6) {
            assertTrue("running count exceeded pool size", runningCount.get() <= 2);
            boolean completedOne = false;
            for (StubEngine engine : engines) {
                if (engine.isRunning()) {
                    engine.succeed("ok");
                    completed++;
                    completedOne = true;
                    break;
                }
            }
            assertTrue("expected a running engine to complete", completedOne);
        }

        assertEquals(2, maxConcurrent.get());
        assertEquals(6, listener.succeededTaskIds.size());
    }

    //
    // Size-1 serial execution: a size-1 pool must never run two tasks at once; the high-water mark
    // of concurrent engines stays at 1 throughout.
    //
    @Test
    public void sizeOnePoolRunsSerially() {
        RecordingPoolListener listener = new RecordingPoolListener();
        EnginePool pool = newPool(listener, 1);

        pool.addTask(task("a", "src"));
        pool.addTask(task("b", "src"));
        pool.addTask(task("c", "src"));

        // Drain serially; assert only one runs at any moment.
        engineRunning("a").succeed("1");
        engineRunning("b").succeed("2");
        engineRunning("c").succeed("3");

        assertEquals(1, maxConcurrent.get());
        assertEquals(Arrays.asList("a", "b", "c"), listener.succeededTaskIds);
    }

    //
    // Cancel drops pending: cancelling a source removes its still-pending tasks from the FIFO so
    // they never dispatch, while tasks of other sources still run.
    //
    @Test
    public void cancelDropsPendingTasks() {
        RecordingPoolListener listener = new RecordingPoolListener();
        EnginePool pool = newPool(listener, 1);

        pool.addTask(task("a", "keep"));
        pool.addTask(task("b", "cancel"));
        pool.addTask(task("c", "cancel"));
        pool.addTask(task("d", "keep"));

        // a is running; b, c, d are pending.
        assertNotNull(engineRunning("a"));

        // Cancel the "cancel" source: b and c are dropped from the FIFO.
        pool.cancelTasks("cancel");

        // Finish a; the next pending that is NOT cancelled is d (b and c were dropped).
        engineRunning("a").succeed("1");
        assertNotNull(engineRunning("d"));
        assertNull(engineRunning("b"));
        assertNull(engineRunning("c"));

        engineRunning("d").succeed("4");

        // Only a and d ever ran/completed.
        assertEquals(Arrays.asList("a", "d"), listener.succeededTaskIds);
    }

    //
    // Cancellation of a PENDING (not-yet-running) task, as a distinct case from cancelling a
    // running task. The pending task is dropped and never dispatched, and never appears in any
    // completion list.
    //
    @Test
    public void cancelPendingTaskNeverRuns() {
        RecordingPoolListener listener = new RecordingPoolListener();
        EnginePool pool = newPool(listener, 1);

        pool.addTask(task("running", "src-a"));
        pool.addTask(task("pending", "src-b"));

        // "running" occupies the only engine; "pending" is queued.
        assertNotNull(engineRunning("running"));
        assertNull(engineRunning("pending"));

        // Cancel the pending task's source while it is still pending.
        pool.cancelTasks("src-b");

        // Complete the running task; the cancelled pending task must NOT now dispatch.
        engineRunning("running").succeed("ok");
        assertNull(engineRunning("pending"));

        assertEquals(Arrays.asList("running"), listener.succeededTaskIds);
        assertFalse(listener.succeededTaskIds.contains("pending"));
    }

    //
    // Cancellation of a RUNNING task: the running task's atomic cancelled flag is set so the
    // handler can observe it via host.isCancelled, distinct from the pending-drop case above.
    //
    @Test
    public void cancelRunningTaskSetsFlag() {
        RecordingPoolListener listener = new RecordingPoolListener();
        EnginePool pool = newPool(listener, 1);

        pool.addTask(task("running", "src"));
        assertNotNull(engineRunning("running"));
        assertFalse(pool.getCancellationState().isCancelled("running"));

        pool.cancelTasks("src");

        // The running task observes cancellation via the lock-free flag.
        assertTrue(pool.getCancellationState().isCancelled("running"));
    }

    //
    // Shutdown disposes every engine and stops further dispatch.
    //
    @Test
    public void shutdownDisposesEnginesAndStopsDispatch() {
        RecordingPoolListener listener = new RecordingPoolListener();
        EnginePool pool = newPool(listener, 2);

        pool.addTask(task("a", "src"));
        pool.shutdown();

        for (StubEngine engine : engines) {
            assertTrue(engine.isDisposed());
        }

        // After shutdown, adding a task does not dispatch it (no engine starts running).
        runningCount.set(0);
        pool.addTask(task("b", "src"));
        assertNull(engineRunning("b"));
    }
}
