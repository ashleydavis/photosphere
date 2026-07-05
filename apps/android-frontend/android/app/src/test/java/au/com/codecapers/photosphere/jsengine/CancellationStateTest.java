package au.com.codecapers.photosphere.jsengine;

import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

//
// Plain-JVM unit tests for the per-task cancellation flags. Pure in-memory state, no Android
// dependencies, so it runs directly on the JVM.
//
public final class CancellationStateTest {

    //
    // The state under test.
    //
    private final CancellationState cancellationState = new CancellationState();

    @Test
    public void unknownTaskReadsAsNotCancelled() {
        assertFalse(cancellationState.isCancelled("never-registered"));
    }

    @Test
    public void registeredTaskStartsWithItsInitialFlag() {
        cancellationState.register("task-a", false);
        assertFalse(cancellationState.isCancelled("task-a"));

        cancellationState.register("task-b", true);
        assertTrue(cancellationState.isCancelled("task-b"));
    }

    @Test
    public void setCancelledFlipsARegisteredTask() {
        cancellationState.register("task-a", false);
        cancellationState.setCancelled("task-a");
        assertTrue(cancellationState.isCancelled("task-a"));
    }

    @Test
    public void setCancelledOnUnknownTaskIsANoOp() {
        // Must not throw, and must not spuriously register the task.
        cancellationState.setCancelled("ghost");
        assertFalse(cancellationState.isCancelled("ghost"));
    }

    @Test
    public void unregisterRemovesTheFlagAndResetsToNotCancelled() {
        cancellationState.register("task-a", true);
        assertTrue(cancellationState.isCancelled("task-a"));
        cancellationState.unregister("task-a");
        assertFalse(cancellationState.isCancelled("task-a"));
    }

    @Test
    public void clearRemovesEveryFlag() {
        cancellationState.register("task-a", true);
        cancellationState.register("task-b", true);
        cancellationState.clear();
        assertFalse(cancellationState.isCancelled("task-a"));
        assertFalse(cancellationState.isCancelled("task-b"));
    }
}
