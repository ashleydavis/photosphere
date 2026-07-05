package au.com.codecapers.photosphere.jsengine;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import org.junit.Rule;
import org.junit.Test;
import org.junit.rules.TemporaryFolder;

import java.util.ArrayList;
import java.util.List;

//
// Plain-JVM unit tests for the host bridge's own dispatch logic: the platform/sessionId accessors, the
// current-task guarded sendMessage/queueChildTask forwards, and the cancellation read. The many thin
// host.* delegations (tcp/udp/tls/crypto/fs/media) are covered by their own runner/host tests; these
// verify the branching the bridge itself owns. The notImplemented/sha256 paths route through
// android.util.Log (not available on the plain JVM) so they are exercised by the iOS bridge tests and
// the on-device smoke tests instead.
//
public final class HostBridgeTest {

    //
    // A fresh temporary storage root per test.
    //
    @Rule
    public TemporaryFolder temporaryFolder = new TemporaryFolder();

    //
    // Records the callback invocations the bridge makes so tests can assert on them.
    //
    private static final class RecordingCallbacks implements EngineCallbacks {

        //
        // Task ids passed to onTaskMessage, in order.
        //
        final List<String> messageTaskIds = new ArrayList<>();

        //
        // Message payloads passed to onTaskMessage, in order.
        //
        final List<String> messages = new ArrayList<>();

        //
        // Parent task ids passed to queueChildTask, in order.
        //
        final List<String> childParentIds = new ArrayList<>();

        //
        // Child task ids passed to queueChildTask, in order.
        //
        final List<String> childTaskIds = new ArrayList<>();

        @Override
        public void onTaskSucceeded(PooledTask task, String outputsJson) {
        }

        @Override
        public void onTaskFailed(PooledTask task, String errorMessage) {
        }

        @Override
        public void onTaskMessage(PooledTask task, String messageJson) {
            messageTaskIds.add(task.taskId);
            messages.add(messageJson);
        }

        @Override
        public void queueChildTask(String parentTaskId, String childTaskId, String type, String dataJson, String source) {
            childParentIds.add(parentTaskId);
            childTaskIds.add(childTaskId);
        }
    }

    //
    // The shared cancellation state read by the bridge.
    //
    private final CancellationState cancellationState = new CancellationState();

    //
    // Recording callbacks the bridge forwards into.
    //
    private final RecordingCallbacks callbacks = new RecordingCallbacks();

    //
    // Builds a bridge wired to the recording callbacks, shared cancellation state, and temp root.
    //
    private HostBridge newBridge() {
        return new HostBridge(callbacks, cancellationState, "session-1", temporaryFolder.getRoot());
    }

    @Test
    public void platformIsAndroid() {
        assertEquals("android", newBridge().getPlatform());
    }

    @Test
    public void sessionIdIsTheConfiguredValue() {
        assertEquals("session-1", newBridge().getSessionId());
    }

    @Test
    public void sendMessageForwardsWhenCurrentTaskMatches() {
        HostBridge bridge = newBridge();
        bridge.setCurrentTask(new PooledTask("task-a", "type", "{}", "src"));
        bridge.sendMessage("task-a", "{\"progress\":1}");
        assertEquals(1, callbacks.messages.size());
        assertEquals("task-a", callbacks.messageTaskIds.get(0));
        assertEquals("{\"progress\":1}", callbacks.messages.get(0));
    }

    @Test
    public void sendMessageIsIgnoredWithoutACurrentTask() {
        HostBridge bridge = newBridge();
        bridge.sendMessage("task-a", "{}");
        assertTrue(callbacks.messages.isEmpty());
    }

    @Test
    public void sendMessageIsIgnoredWhenTaskIdDoesNotMatch() {
        HostBridge bridge = newBridge();
        bridge.setCurrentTask(new PooledTask("task-a", "type", "{}", "src"));
        bridge.sendMessage("task-b", "{}");
        assertTrue(callbacks.messages.isEmpty());
    }

    @Test
    public void queueChildTaskForwardsTaggedWithTheParentTaskId() {
        HostBridge bridge = newBridge();
        bridge.setCurrentTask(new PooledTask("parent-1", "type", "{}", "src"));
        bridge.queueChildTask("child-1", "childType", "{}", "src");
        assertEquals(1, callbacks.childTaskIds.size());
        assertEquals("parent-1", callbacks.childParentIds.get(0));
        assertEquals("child-1", callbacks.childTaskIds.get(0));
    }

    @Test
    public void queueChildTaskIsIgnoredWithoutACurrentTask() {
        HostBridge bridge = newBridge();
        bridge.queueChildTask("child-1", "childType", "{}", "src");
        assertTrue(callbacks.childTaskIds.isEmpty());
    }

    @Test
    public void isCancelledReflectsCancellationState() {
        HostBridge bridge = newBridge();
        assertFalse(bridge.isCancelled("task-a"));
        cancellationState.register("task-a", false);
        cancellationState.setCancelled("task-a");
        assertTrue(bridge.isCancelled("task-a"));
    }
}
