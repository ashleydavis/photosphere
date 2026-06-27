package au.com.codecapers.photosphere.jsengine;

import java.io.File;

//
// The native object installed into each engine context as globalThis.host. The embedded
// worker calls these methods synchronously from inside running task handlers. This class
// is the single dispatch point for host functions: the three implemented for the first
// slice (sendMessage, isCancelled, sha256) plus platform/sessionId, and an explicit
// unknown-method path that throws the verbatim NOT IMPLEMENTED error.
//
// Quack exposes a plain Java object's public methods to JS by name, so the method names
// here ARE the JS-callable host.* names. Each host engine constructs one HostBridge per
// context. All methods are thread-safe: sha256 is stateless, isCancelled reads the
// lock-free CancellationState, and sendMessage's hand-off into the pool is itself
// non-reentrant.
//
public final class HostBridge {

    //
    // The currently running task on this engine context, set by the engine immediately
    // before runTask so host.sendMessage/isCancelled know which task is calling. Volatile
    // because the engine sets it and the (same-thread) JS calls read it; volatile keeps the
    // intent explicit and is safe if a future change moves the read off-thread.
    //
    private volatile PooledTask currentTask;

    //
    // The callbacks used to surface streamed messages back to the pool/plugin.
    //
    private final EngineCallbacks callbacks;

    //
    // The shared cancellation state, polled lock-free by isCancelled.
    //
    private final CancellationState cancellationState;

    //
    // The single pool-owned session id handed to the worker as host.sessionId.
    //
    private final String sessionId;

    //
    // The sandbox storage root every path-taking host function resolves against.
    //
    private final File storageRoot;

    //
    // Constructs the bridge for one engine context.
    //
    public HostBridge(EngineCallbacks callbacks, CancellationState cancellationState, String sessionId, File storageRoot) {
        this.callbacks = callbacks;
        this.cancellationState = cancellationState;
        this.sessionId = sessionId;
        this.storageRoot = storageRoot;
    }

    //
    // Sets the task that is about to run on this context. Called by the engine before
    // invoking runTask, and cleared after.
    //
    public void setCurrentTask(PooledTask task) {
        this.currentTask = task;
    }

    //
    // host.platform: the constant string "android".
    //
    public String getPlatform() {
        return HostFunctions.PLATFORM;
    }

    //
    // host.sessionId: the single pool-owned session id shared by every engine.
    //
    public String getSessionId() {
        return sessionId;
    }

    //
    // host.sendMessage(taskId, messageJson): synchronous native callable invoked when the
    // running handler streams a progress message. It forwards the raw JSON message into the
    // pool, which emits a taskMessage event. No dispatcher lock is taken here; the pool's
    // listener hand-off is non-reentrant with the engine event loop.
    //
    public void sendMessage(String taskId, String messageJson) {
        PooledTask task = currentTask;
        if (task != null && task.taskId.equals(taskId)) {
            callbacks.onTaskMessage(task, messageJson);
        }
    }

    //
    // host.isCancelled(taskId): synchronous native callable returning whether the task has
    // been cancelled. Reads the lock-free atomic flag so a running handler can poll it
    // cheaply mid-task without contending on the dispatcher lock.
    //
    public boolean isCancelled(String taskId) {
        return cancellationState.isCancelled(taskId);
    }

    //
    // host.sha256(path): hashes the file at the sandboxed storage path natively and returns
    // the lowercase hex digest. The path is validated by PathSandbox before any IO.
    //
    public String sha256(String path) {
        return HostFunctions.sha256(storageRoot, path);
    }

    //
    // The unknown-method path. Any host function the bundle expects that native did not
    // install must surface as a loud, verbatim NOT IMPLEMENTED failure. The JS side installs
    // throwing stubs for missing methods, and this helper is available for any native host
    // method that is declared but not finished to throw the identical message from its body.
    //
    public Object notImplemented(String name) {
        throw HostFunctions.notImplemented(name);
    }
}
