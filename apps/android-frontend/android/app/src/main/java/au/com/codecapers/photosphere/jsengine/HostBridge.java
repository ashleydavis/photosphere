package au.com.codecapers.photosphere.jsengine;

import android.content.Context;

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
    // The Android context the device photo library is read through, or null on a bridge created
    // without one (the plain-JVM unit tests). The library reader is only built when something asks
    // for it, so a bridge with no context works for everything else.
    //
    private final Context androidContext;

    //
    // Constructs the bridge for one engine context, without an Android context. For tests, and for
    // anything that will never read the device photo library.
    //
    public HostBridge(EngineCallbacks callbacks, CancellationState cancellationState, String sessionId, File storageRoot) {
        this(callbacks, cancellationState, sessionId, storageRoot, null);
    }

    //
    // Constructs the bridge for one engine context, with the Android context the device photo
    // library needs.
    //
    public HostBridge(EngineCallbacks callbacks, CancellationState cancellationState, String sessionId, File storageRoot, Context androidContext) {
        this.callbacks = callbacks;
        this.cancellationState = cancellationState;
        this.sessionId = sessionId;
        this.storageRoot = storageRoot;
        this.androidContext = androidContext;
    }

    //
    // The device photo library, created lazily and only when automatic import actually reads it.
    //
    private MediaLibraryHost mediaLibraryHost;

    //
    // Returns the device photo library reader, creating it on first use.
    //
    private synchronized MediaLibraryHost mediaLibrary() {
        if (mediaLibraryHost == null) {
            if (androidContext == null) {
                throw new RuntimeException("The device photo library needs an Android context, and this engine was created without one.");
            }
            mediaLibraryHost = new MediaLibraryHost(androidContext, storageRoot);
            mediaLibraryHost.setDeleteRequester(MediaDeleteBroker.requester());
        }
        return mediaLibraryHost;
    }

    //
    // host.mediaLibraryList(cursor, pageSize): one page of the device photo library, as JSON.
    //
    public String mediaLibraryList(String cursor, int pageSize) {
        return mediaLibrary().mediaLibraryList(cursor, pageSize);
    }

    //
    // host.mediaLibraryAlbums(): the albums in the device photo library, as JSON.
    //
    public String mediaLibraryAlbums() {
        return mediaLibrary().mediaLibraryAlbums();
    }

    //
    // host.mediaLibraryOpen(itemId): copies one library item into the sandbox and returns its path.
    //
    public String mediaLibraryOpen(String itemId) {
        return mediaLibrary().mediaLibraryOpen(itemId);
    }

    //
    // host.mediaLibraryClose(itemId): deletes the sandbox copy an open made.
    //
    public void mediaLibraryClose(String itemId) {
        mediaLibrary().mediaLibraryClose(itemId);
    }

    //
    // host.mediaLibraryDelete(itemIdsJson): asks to delete the named items from the photo library.
    //
    public String mediaLibraryDelete(String itemIdsJson) {
        return mediaLibrary().mediaLibraryDelete(itemIdsJson);
    }

    //
    // The reporter of what kind of connection the phone has, built on first use.
    //
    private NetworkHost networkHost;

    //
    // Returns the connection reporter, creating it on first use.
    //
    private synchronized NetworkHost network() {
        if (networkHost == null) {
            if (androidContext == null) {
                throw new RuntimeException("Reading the connection type needs an Android context, and this engine was created without one.");
            }
            networkHost = new NetworkHost(androidContext);
        }
        return networkHost;
    }

    //
    // host.networkConnectionType(): "wifi", "cellular", "none" or "unknown".
    //
    // Asked for by the background sync, which cannot ask the WebView because there may not be one.
    // A bridge with no Android context throws rather than answering "unknown": "unknown" is a value
    // the sync gate permits, so guessing it would push photos over a connection nobody identified.
    //
    public String networkConnectionType() {
        return network().connectionType();
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
    // host.tcpConnect(host, port): opens an outbound TCP connection and returns JSON { connectionId }.
    //
    public String tcpConnect(String host, int port) {
        return tcp.tcpConnect(host, port);
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
    // The native UDP layer behind the host.udp* functions. Owned per engine context; the engine drains
    // its inbound event queue on the worker thread. Public so the run loop can poll and check liveness.
    //
    public final UdpHost udp = new UdpHost();

    //
    // host.udpBind(host, port, broadcast): binds a UDP socket and returns JSON { socketId, port }.
    //
    public String udpBind(String host, int port, boolean broadcast) {
        return udp.udpBind(host, port, broadcast);
    }

    //
    // host.udpSend(socketId, base64, host, port): sends a datagram to host/port.
    //
    public String udpSend(String socketId, String base64, String host, int port) {
        return udp.udpSend(socketId, base64, host, port);
    }

    //
    // host.udpClose(socketId): closes a UDP socket.
    //
    public String udpClose(String socketId) {
        return udp.udpClose(socketId);
    }

    //
    // The native TLS layer behind the host.tls* functions. Owned per engine context; the engine drains
    // its inbound event queue on the worker thread. Public so the run loop can poll and check liveness.
    //
    public final TlsHost tls = new TlsHost();

    //
    // host.tlsListen(host, port, certPem, keyPem): binds a TLS listener and returns JSON { listenerId, port }.
    //
    public String tlsListen(String host, int port, String certPem, String keyPem) {
        return tls.tlsListen(host, port, certPem, keyPem);
    }

    //
    // host.tlsConnect(host, port, rejectUnauthorized): opens a cert-capturing TLS client and returns
    // JSON { connectionId, peerCertBase64 }. rejectUnauthorized is Node's option: true validates the
    // chain and hostname, false trusts any certificate so the JS side can pin it.
    //
    public String tlsConnect(String host, int port, boolean rejectUnauthorized) {
        return tls.tlsConnect(host, port, rejectUnauthorized);
    }

    //
    // host.tlsWrite(connectionId, base64): writes bytes to a TLS connection.
    //
    public String tlsWrite(String connectionId, String base64) {
        return tls.tlsWrite(connectionId, base64);
    }

    //
    // host.tlsClose(connectionId): closes one TLS connection.
    //
    public String tlsClose(String connectionId) {
        return tls.tlsClose(connectionId);
    }

    //
    // host.tlsStopListening(listenerId): closes a TLS listener.
    //
    public String tlsStopListening(String listenerId) {
        return tls.tlsStopListening(listenerId);
    }

    //
    // host.cryptoGenerateRsaKeyPair(modulusLength): generates an RSA key pair as JSON { privateKeyPem, publicKeyPem }.
    //
    public String cryptoGenerateRsaKeyPair(int modulusLength) {
        return CryptoHost.cryptoGenerateRsaKeyPair(modulusLength);
    }

    //
    // host.cryptoSignSha256(privateKeyPem, dataBase64): signs data with SHA256withRSA, returning a base64 signature.
    //
    public String cryptoSignSha256(String privateKeyPem, String dataBase64) {
        return CryptoHost.cryptoSignSha256(privateKeyPem, dataBase64);
    }

    //
    // host.cryptoPublicEncryptOaepSha1(publicKeyPem, dataBase64): RSA-OAEP-SHA1 encrypt, returning base64.
    //
    public String cryptoPublicEncryptOaepSha1(String publicKeyPem, String dataBase64) {
        return CryptoHost.cryptoPublicEncryptOaepSha1(publicKeyPem, dataBase64);
    }

    //
    // host.cryptoPrivateDecryptOaepSha1(privateKeyPem, dataBase64): RSA-OAEP-SHA1 decrypt, returning base64.
    //
    public String cryptoPrivateDecryptOaepSha1(String privateKeyPem, String dataBase64) {
        return CryptoHost.cryptoPrivateDecryptOaepSha1(privateKeyPem, dataBase64);
    }

    //
    // host.cryptoPublicKeyFromPrivate(privateKeyPem): derives the SPKI PEM public key from a PKCS#8 PEM private key.
    //
    public String cryptoPublicKeyFromPrivate(String privateKeyPem) {
        return CryptoHost.cryptoPublicKeyFromPrivate(privateKeyPem);
    }

    //
    // host.secureStoreGet(key): reads a secret from the device keychain, returning its value or null.
    //
    public String secureStoreGet(String key) {
        return SecureStoreHost.secureStoreGet(key);
    }

    //
    // host.secureStoreSet(key, value): writes (or overwrites) a secret in the device keychain.
    //
    public void secureStoreSet(String key, String value) {
        SecureStoreHost.secureStoreSet(key, value);
    }

    //
    // host.secureStoreDelete(key): deletes a secret from the device keychain (a missing key is not an error).
    //
    public void secureStoreDelete(String key) {
        SecureStoreHost.secureStoreDelete(key);
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
    // host.queueTask(childTaskId, type, dataJson, source, priority): synchronous native callable
    // invoked when the running handler enqueues a child task. It hands the child to the pool tagged
    // with the currently-running (parent) task id so the pool can route the child's outcome back to
    // this engine. Mirrors the Electron worker posting a "queue-task" message to the main process.
    // `priorityWireName` is null when the handler named no priority, and the pool then runs the child
    // at its parent's priority.
    //
    public void queueChildTask(String childTaskId, String type, String dataJson, String source, String priorityWireName) {
        PooledTask parent = currentTask;
        if (parent != null) {
            callbacks.queueChildTask(parent.taskId, childTaskId, type, dataJson, source, priorityWireName);
        }
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
    // host.fsReadFileRange(path, offset, length): reads a byte range of a sandboxed file. Backs the
    // mobile fs shim's ranged read, which is what lets a photo's EXIF be read without the whole photo
    // crossing the bridge.
    //
    public String fsReadFileRange(String path, int offset, int length) {
        return HostFunctions.fsReadFileRange(storageRoot, path, offset, length);
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
    // host.fsCopyFile(srcPath, destPath): copies a sandboxed file natively. Backs the mobile fs
    // shim's copyFile, which storage uses to put an imported photo into the database without the
    // photo ever crossing the bridge as base64.
    //
    public void fsCopyFile(String srcPath, String destPath) {
        HostFunctions.fsCopyFile(storageRoot, srcPath, destPath);
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
    // The ImageMagick runner (host.imageMagick), created lazily. The storage root doubles as the
    // writable cache dir for the per-call stdout capture file.
    //
    private ImageMagickRunner imageMagickRunner;

    //
    // The FFmpegKit runner (host.ffmpeg / host.ffprobe), created lazily.
    //
    private FfmpegKitRunner ffmpegKitRunner;

    //
    // Returns the shared ImageMagick runner, creating it on first use.
    //
    private synchronized ImageMagickRunner imageMagickRunner() {
        if (imageMagickRunner == null) {
            imageMagickRunner = new ImageMagickRunner(storageRoot);
        }
        return imageMagickRunner;
    }

    //
    // Returns the shared FFmpegKit runner, creating it on first use.
    //
    private synchronized FfmpegKitRunner ffmpegKitRunner() {
        if (ffmpegKitRunner == null) {
            ffmpegKitRunner = new FfmpegKitRunner();
        }
        return ffmpegKitRunner;
    }

    //
    // host.imageMagick(argvJson): runs a magick argv in-process (all ImageMagick operations) and
    // returns the JSON string { exitCode, output } (or an @@HOSTERR@@ envelope on failure).
    //
    public String imageMagick(String argvJson) {
        return HostFunctions.runMediaTool(storageRoot, imageMagickRunner(), 0, argvJson);
    }

    //
    // host.ffmpeg(argvJson): runs an ffmpeg argv in-process (e.g. the screenshot extraction).
    //
    public String ffmpeg(String argvJson) {
        return HostFunctions.runMediaTool(storageRoot, ffmpegKitRunner(), 1, argvJson);
    }

    //
    // host.ffprobe(argvJson): runs an ffprobe argv in-process (container/stream metadata JSON).
    //
    public String ffprobe(String argvJson) {
        return HostFunctions.runMediaTool(storageRoot, ffmpegKitRunner(), 2, argvJson);
    }

    //
    // The unknown-method path. Any host function the bundle expects that native did not
    // install must surface as a loud, verbatim NOT IMPLEMENTED failure. The JS side installs
    // throwing functions for missing methods, and this helper is available for any native host
    // method that is declared but not finished to throw the identical message from its body.
    //
    public Object notImplemented(String name) {
        throw HostFunctions.notImplemented(name);
    }
}
