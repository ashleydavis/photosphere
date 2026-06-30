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
    // The native TCP socket layer behind the host.tcp* functions. Owned per engine context; the
    // engine drains its inbound event queue on the worker thread. Public so the engine run loop can
    // poll inbound events and check whether a server is still listening.
    //
    public final TcpHost tcp = new TcpHost();

    //
    // host.tcpListen(host, port): binds a loopback TCP listener and returns JSON { listenerId, port }.
    //
    public String tcpListen(String host, int port) {
        return tcp.tcpListen(host, port);
    }

    //
    // host.tcpWrite(connectionId, base64): writes bytes to an accepted connection.
    //
    public String tcpWrite(String connectionId, String base64) {
        return tcp.tcpWrite(connectionId, base64);
    }

    //
    // host.tcpClose(connectionId): closes one accepted connection.
    //
    public String tcpClose(String connectionId) {
        return tcp.tcpClose(connectionId);
    }

    //
    // host.tcpStopListening(listenerId): closes a TCP listener.
    //
    public String tcpStopListening(String listenerId) {
        return tcp.tcpStopListening(listenerId);
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
    // host.fsReadFile(path): reads a sandboxed file and returns its bytes as base64 (or null when
    // missing). Backs the mobile fs shim's readFile/createReadStream.
    //
    public String fsReadFile(String path) {
        return HostFunctions.fsReadFile(storageRoot, path);
    }

    //
    // host.fsAccess(path): returns whether a sandboxed file or directory exists. Backs pathExists.
    //
    public boolean fsAccess(String path) {
        return HostFunctions.fsAccess(storageRoot, path);
    }

    //
    // host.fsStat(path): returns a JSON stat string for a sandboxed path (or null when missing).
    //
    public String fsStat(String path) {
        return HostFunctions.fsStat(storageRoot, path);
    }

    //
    // host.fsReaddir(path): returns a JSON directory listing for a sandboxed path (or null when
    // missing). Backs the mobile fs shim's readdir.
    //
    public String fsReaddir(String path) {
        return HostFunctions.fsReaddir(storageRoot, path);
    }

    //
    // host.fsWriteFile(path, base64, exclusive): writes base64-decoded bytes to a sandboxed path.
    // Backs the mobile fs shim's writeFile (exclusive maps the Node 'wx' flag).
    //
    public void fsWriteFile(String path, String base64, boolean exclusive) {
        HostFunctions.fsWriteFile(storageRoot, path, base64, exclusive);
    }

    //
    // host.fsMkdir(path, recursive): creates a sandboxed directory. Backs the mobile fs shim's mkdir.
    //
    public void fsMkdir(String path, boolean recursive) {
        HostFunctions.fsMkdir(storageRoot, path, recursive);
    }

    //
    // host.fsRename(srcPath, destPath): renames/moves a sandboxed file. Backs the mobile fs shim's
    // rename.
    //
    public void fsRename(String srcPath, String destPath) {
        HostFunctions.fsRename(storageRoot, srcPath, destPath);
    }

    //
    // host.fsUnlink(path): deletes a sandboxed file. Backs the mobile fs shim's unlink.
    //
    public void fsUnlink(String path) {
        HostFunctions.fsUnlink(storageRoot, path);
    }

    //
    // host.fsRm(path, recursive, force): deletes a sandboxed file or directory tree. Backs the mobile
    // fs shim's rm.
    //
    public void fsRm(String path, boolean recursive, boolean force) {
        HostFunctions.fsRm(storageRoot, path, recursive, force);
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
