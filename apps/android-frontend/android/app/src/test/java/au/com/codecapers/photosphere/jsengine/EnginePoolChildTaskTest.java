package au.com.codecapers.photosphere.jsengine;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.concurrent.atomic.AtomicInteger;

//
// Plain-JVM unit tests for child-task (subtask) routing in the engine pool. A child task queued
// from inside a running handler must dispatch to a free engine and have its outcome routed back to
// the engine that spawned it (so an orchestrator awaiting the subtask resolves), NOT to the plugin
// listener that feeds the WebView. This mirrors Electron keeping child-task results off the renderer.
//
public final class EnginePoolChildTaskTest {

    //
    // Shared counter of currently-running stub engines (unused assertions here, required by StubEngine).
    //
    private final AtomicInteger runningCount = new AtomicInteger(0);

    //
    // High-water mark of concurrent running engines (required by StubEngine).
    //
    private final AtomicInteger maxConcurrent = new AtomicInteger(0);

    //
    // The stub engines created by the factory, in slot order.
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
    // Builds a task with the given id and source.
    //
    private PooledTask task(String taskId, String source) {
        return new PooledTask(taskId, "test-type", "{}", source);
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
    // A child task's successful completion is routed back to the engine that spawned it, and NOT to
    // the plugin listener. The parent (root) task's own completion still goes to the listener.
    //
    @Test
    public void childSuccessRoutesToOriginEngineNotListener() {
        RecordingPoolListener listener = new RecordingPoolListener();
        EnginePool pool = newPool(listener, 3);

        pool.addTask(task("parent", "import"));
        StubEngine parentEngine = engineRunning("parent");
        assertNotNull(parentEngine);

        // The running parent spawns a child; it dispatches to a different, idle engine.
        pool.queueChildTask("parent", new PooledTask("child", "hash-file", "{\"filePath\":\"a.jpg\"}", "session"));
        StubEngine childEngine = engineRunning("child");
        assertNotNull(childEngine);
        assertTrue(childEngine != parentEngine);

        // Completing the child routes the result back to the parent's engine, not the listener.
        childEngine.succeed("{\"hash\":\"abc\"}");
        assertEquals(0, listener.succeededTaskIds.size());
        assertEquals(1, parentEngine.deliveredChildEvents.size());
        assertEquals(Boolean.TRUE, parentEngine.deliveredChildTerminals.get(0));

        String event = parentEngine.deliveredChildEvents.get(0);
        assertTrue(event.contains("\"kind\":\"completed\""));
        assertTrue(event.contains("\"taskId\":\"child\""));
        assertTrue(event.contains("\"status\":\"succeeded\""));
        assertTrue(event.contains("\"outputs\":{\"hash\":\"abc\"}"));

        // The parent (root) task's own completion still goes to the WebView listener.
        parentEngine.succeed("null");
        assertEquals(Arrays.asList("parent"), listener.succeededTaskIds);
    }

    //
    // A child task's failure is routed back to the origin engine as a "failed" completion event
    // carrying the error message, not to the listener.
    //
    @Test
    public void childFailureRoutesToOriginEngine() {
        RecordingPoolListener listener = new RecordingPoolListener();
        EnginePool pool = newPool(listener, 3);

        pool.addTask(task("parent", "import"));
        StubEngine parentEngine = engineRunning("parent");

        pool.queueChildTask("parent", new PooledTask("child", "hash-file", "{}", "session"));
        StubEngine childEngine = engineRunning("child");
        childEngine.fail("hashing failed");

        assertEquals(0, listener.failedTaskIds.size());
        assertEquals(1, parentEngine.deliveredChildEvents.size());
        String event = parentEngine.deliveredChildEvents.get(0);
        assertTrue(event.contains("\"status\":\"failed\""));
        assertTrue(event.contains("\"errorMessage\":\"hashing failed\""));
    }

    //
    // A child task's streamed message goes to the plugin listener (the WebView), NOT the origin
    // engine, matching Electron: the UI consumes subtask messages (e.g. import-pending sent by the
    // upload-asset subtask). Only child completions route back to the origin engine.
    //
    @Test
    public void childMessageRoutesToWebViewListenerNotOriginEngine() {
        RecordingPoolListener listener = new RecordingPoolListener();
        EnginePool pool = newPool(listener, 3);

        pool.addTask(task("parent", "import"));
        StubEngine parentEngine = engineRunning("parent");

        pool.queueChildTask("parent", new PooledTask("child", "hash-file", "{}", "session"));
        StubEngine childEngine = engineRunning("child");
        childEngine.emitMessage("{\"type\":\"progress\",\"percent\":50}");

        // The message reaches the WebView listener and does NOT go to the origin engine.
        assertEquals(Arrays.asList("child"), listener.messageTaskIds);
        assertEquals(0, parentEngine.deliveredChildEvents.size());
    }

    //
    // A child whose parent is no longer running is dropped: there is no engine to deliver its result
    // to, so it never dispatches.
    //
    @Test
    public void childWithNoRunningParentIsDropped() {
        RecordingPoolListener listener = new RecordingPoolListener();
        EnginePool pool = newPool(listener, 3);

        pool.queueChildTask("ghost-parent", new PooledTask("child", "hash-file", "{}", "session"));
        assertNull(engineRunning("child"));
    }

    //
    // A child whose source was already cancelled is dropped before dispatch.
    //
    @Test
    public void childWithCancelledSourceIsDropped() {
        RecordingPoolListener listener = new RecordingPoolListener();
        EnginePool pool = newPool(listener, 3);

        pool.addTask(task("parent", "import"));
        assertNotNull(engineRunning("parent"));

        pool.cancelTasks("session");
        pool.queueChildTask("parent", new PooledTask("child", "hash-file", "{}", "session"));
        assertNull(engineRunning("child"));
    }
}
