package au.com.codecapers.photosphere.jsengine;

import android.content.Context;
import android.util.Log;

import com.whl.quickjs.android.QuickJSLoader;
import com.whl.quickjs.wrapper.JSCallFunction;
import com.whl.quickjs.wrapper.JSObject;
import com.whl.quickjs.wrapper.QuickJSContext;

import java.io.BufferedReader;
import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.TimeUnit;
import java.util.function.BooleanSupplier;
import java.util.function.Supplier;

//
// The production TaskEngine that runs the embedded worker bundle in a QuickJS context, using the
// QuickJSWrapper binding (wang.harlon.quickjs). Each instance owns a single dedicated worker
// thread (a single-thread ExecutorService); the QuickJSContext is created and used ONLY on that
// thread because contexts are not thread-safe. worker.bundle.js is evaluated once when the
// context is first created, the host bridge is installed as globalThis.host, and each runTask
// call marshals the task as JSON strings and drives globalThis.__photosphereWorker.runTask(...).
//
// Engine fallback note: Rhino is a documented pure-JVM, NDK-free, SYNC-ONLY fallback. It has no
// async/await, so the async handlers would need transpiling and reducing to synchronous form to
// run on it. It is intentionally NOT wired here; QuickJS is the target because it runs the async
// handlers unchanged.
//
public final class QuickJsTaskEngine implements TaskEngine {

    //
    // Loads the QuickJS native library once for the process before any context is created.
    //
    static {
        QuickJSLoader.init();
    }

    //
    // Log tag for engine diagnostics.
    //
    private static final String LOG_TAG = "JsEngineQuickJs";

    //
    // The asset filename of the compiled worker bundle, shipped inside the signed app. It is only
    // ever loaded from this packaged asset, never from a remote/OTA source.
    //
    private static final String BUNDLE_ASSET_NAME = "worker.bundle.js";

    //
    // The Android context used to open the bundle asset.
    //
    private final Context androidContext;

    //
    // The shared cancellation state passed into the host bridge.
    //
    private final CancellationState cancellationState;

    //
    // The single pool-owned session id passed into the host bridge.
    //
    private final String sessionId;

    //
    // The sandbox storage root passed into the host bridge.
    //
    private final File storageRoot;

    //
    // This engine's dedicated single worker thread. All QuickJSContext access happens here.
    //
    private final ExecutorService worker = Executors.newSingleThreadExecutor();

    //
    // The QuickJS context, created lazily on the worker thread on first task. Accessed only from
    // the worker thread.
    //
    private QuickJSContext context;

    //
    // The host bridge installed into the context, reused across tasks (its current-task field is
    // updated per task). Accessed only from the worker thread.
    //
    private HostBridge hostBridge;

    //
    // A child-task event (completion or streamed message) queued by the pool for delivery into this
    // engine's run loop. `terminal` marks a completion so the engine can stop treating that child
    // as outstanding.
    //
    private static final class PendingChildEvent {

        //
        // The JSON delivered into globalThis.__childEvent.
        //
        final String json;

        //
        // True for a child completion, false for a streamed message.
        //
        final boolean terminal;

        //
        // Constructs a pending child event.
        //
        PendingChildEvent(String json, boolean terminal) {
            this.json = json;
            this.terminal = terminal;
        }
    }

    //
    // Inbound child-task events from the pool, awaiting delivery into this engine's run loop. Filled
    // from other engines' worker threads (deliverChildEvent), drained on this engine's worker thread.
    //
    private final LinkedBlockingQueue<PendingChildEvent> childEvents = new LinkedBlockingQueue<>();

    //
    // Count of child tasks this engine's current handler has spawned and not yet seen complete. While
    // it is positive the task is long-running (an orchestrator awaiting its subtasks), so the run loop
    // parks for the next child event instead of counting toward the idle timeout. Touched only on the
    // worker thread (incremented in host.queueTask, decremented when a terminal child event is drained).
    //
    private int outstandingChildren;

    //
    // Constructs an engine. The QuickJS context is not created until the first task runs.
    //
    public QuickJsTaskEngine(Context androidContext, CancellationState cancellationState, String sessionId, File storageRoot) {
        this.androidContext = androidContext;
        this.cancellationState = cancellationState;
        this.sessionId = sessionId;
        this.storageRoot = storageRoot;
    }

    //
    // Runs a task on this engine's worker thread. Submits the work to the single-thread executor
    // and returns immediately, so the pool dispatcher is never blocked. Exactly one terminal
    // callback is invoked when the task finishes.
    //
    @Override
    public void runTask(PooledTask task, EngineCallbacks callbacks) {
        worker.submit(() -> runTaskOnWorkerThread(task, callbacks));
    }

    //
    // Queues a child-task event from the pool for delivery into this engine's run loop. Called from
    // another engine's worker thread when a child task this engine spawned completes or streams a
    // message; the LinkedBlockingQueue is thread-safe and the parked run loop wakes to drain it.
    //
    @Override
    public void deliverChildEvent(String eventJson, boolean terminal) {
        childEvents.offer(new PendingChildEvent(eventJson, terminal));
    }

    //
    // Polls the child-event queue up to the given timeout, returning null on timeout. Restores the
    // interrupt flag and returns null if interrupted so the run loop keeps its checked-exception-free shape.
    //
    private PendingChildEvent pollChildEvent(long timeoutMillis) {
        try {
            return childEvents.poll(timeoutMillis, TimeUnit.MILLISECONDS);
        }
        catch (InterruptedException error) {
            Thread.currentThread().interrupt();
            return null;
        }
    }

    //
    // The body that runs on the dedicated worker thread: ensures the context exists, points the
    // host bridge at the current task, drives the embedded runTask, drains the returned promise
    // to a JSON result string, and reports it. Any thrown error becomes an onTaskFailed callback
    // so the task fails loudly (including the NOT IMPLEMENTED case).
    //
    private void runTaskOnWorkerThread(PooledTask task, EngineCallbacks callbacks) {
        try {
            ensureContext(callbacks);
            hostBridge.setCurrentTask(task);

            // Reset per-task subtask state: this engine context is reused across tasks, so clear any
            // stray child events and the outstanding-children count from a previous (e.g. cancelled) run.
            outstandingChildren = 0;
            childEvents.clear();

            JSObject globalObject = context.getGlobalObject();
            globalObject.setProperty("__ptId", task.taskId);
            globalObject.setProperty("__ptType", task.type);
            globalObject.setProperty("__ptData", task.dataJson);

            // runTask returns a Promise resolving to the handler's JSON output string. Resolve it
            // onto a global, then read it. The handler does its work synchronously, so the promise
            // settles within the QuickJS job queue the wrapper drains during evaluate.
            context.evaluate(
                "globalThis.__ptResult = undefined; globalThis.__ptError = undefined;"
                    + "Promise.resolve(globalThis.__photosphereWorker.runTask(globalThis.__ptId, globalThis.__ptType, globalThis.__ptData))"
                    + ".then(function (output) { globalThis.__ptResult = (output === undefined || output === null) ? 'null' : output; })"
                    + ".catch(function (error) { globalThis.__ptError = (error && error.message) ? error.message : String(error); });",
                "photosphere-runTask");

            String outputsJson = null;
            String errorMessage = null;
            // Counts iterations only while no server (TCP listener) is bound, so a normal task that
            // never settles still fails fast; a long-running asset-server task (which keeps a listener
            // open) runs until it is cancelled.
            int idleAttempts = 0;
            while (true) {
                Object result = globalObject.getProperty("__ptResult");
                if (result instanceof String) {
                    outputsJson = (String) result;
                    break;
                }
                Object error = globalObject.getProperty("__ptError");
                if (error instanceof String) {
                    errorMessage = (String) error;
                    break;
                }

                // Deliver any inbound TCP events (connection / data / close) into the JS net shim on
                // this worker thread. This drives the embedded asset server: each delivered request
                // runs express and writes its response back through host.tcpWrite synchronously.
                boolean deliveredEvent = false;
                String tcpEvent = hostBridge.tcp.pollInboundEvent();
                while (tcpEvent != null) {
                    deliverTcpEvent(globalObject, tcpEvent);
                    deliveredEvent = true;
                    tcpEvent = hostBridge.tcp.pollInboundEvent();
                }

                // Deliver inbound UDP datagrams (LAN-share discovery) into the JS dgram shim.
                String udpEvent = hostBridge.udp.pollInboundEvent();
                while (udpEvent != null) {
                    deliverInboundEvent(globalObject, "__udpEvent", udpEvent);
                    deliveredEvent = true;
                    udpEvent = hostBridge.udp.pollInboundEvent();
                }

                // Deliver inbound TLS events (LAN-share HTTPS transfer) into the JS tls shim.
                String tlsEvent = hostBridge.tls.pollInboundEvent();
                while (tlsEvent != null) {
                    deliverInboundEvent(globalObject, "__tlsEvent", tlsEvent);
                    deliveredEvent = true;
                    tlsEvent = hostBridge.tls.pollInboundEvent();
                }

                // Deliver inbound child-task events (subtask completions / messages) into the JS
                // worker backend so an orchestrator handler awaiting its subtasks can resolve. A
                // terminal (completion) event decrements the outstanding-children count.
                PendingChildEvent childEvent = childEvents.poll();
                while (childEvent != null) {
                    deliverInboundEvent(globalObject, "__childEvent", childEvent.json);
                    if (childEvent.terminal) {
                        outstandingChildren--;
                    }
                    deliveredEvent = true;
                    childEvent = childEvents.poll();
                }

                // Drain any remaining QuickJS jobs (promise callbacks). Evaluating drains the whole
                // microtask queue to empty.
                context.evaluate("void 0;");

                // Re-check before advancing a timer: if the task settled while draining microtasks,
                // do not fire any pending timer (e.g. a retry timeout guard).
                if (globalObject.getProperty("__ptResult") instanceof String
                        || globalObject.getProperty("__ptError") instanceof String) {
                    continue;
                }

                // The engine has no real clock: with the microtask queue drained and the task still
                // unsettled, advance the earliest pending timer (setTimeout) so timer-driven progress
                // (retry backoff, timeout guards, the asset-server keep-alive poll) can happen.
                context.evaluate("globalThis.__ptPumped = (typeof globalThis.__pumpTimers === 'function') ? globalThis.__pumpTimers() : false;");
                boolean pumped = Boolean.TRUE.equals(globalObject.getProperty("__ptPumped"));

                // A live "port" is any bound TCP listener, TLS listener, or UDP socket. The asset-server
                // task keeps a TCP listener; a LAN-share receiver keeps a TLS listener plus a broadcasting
                // UDP socket; a LAN-share sender's discovery keeps a UDP socket. While any is live the task
                // is long-running, so park for the next inbound event instead of counting toward the idle
                // limit. Prefer the TLS queue (the receiver's HTTPS request) for the lowest latency.
                boolean tlsLive = hostBridge.tls.hasLiveListeners() || hostBridge.tls.hasLiveConnections();
                boolean anyPortLive = hostBridge.tcp.hasLiveListeners()
                    || tlsLive
                    || hostBridge.udp.hasLiveSockets();
                if (anyPortLive) {
                    if (!deliveredEvent) {
                        String waited = null;
                        if (tlsLive) {
                            waited = hostBridge.tls.awaitInboundEvent(50);
                            if (waited != null) {
                                deliverInboundEvent(globalObject, "__tlsEvent", waited);
                            }
                        }
                        else if (hostBridge.udp.hasLiveSockets()) {
                            waited = hostBridge.udp.awaitInboundEvent(50);
                            if (waited != null) {
                                deliverInboundEvent(globalObject, "__udpEvent", waited);
                            }
                        }
                        else {
                            waited = hostBridge.tcp.awaitInboundEvent(50);
                            if (waited != null) {
                                deliverTcpEvent(globalObject, waited);
                            }
                        }
                        if (waited != null) {
                            context.evaluate("void 0;");
                        }
                    }
                    idleAttempts = 0;
                }
                else if (outstandingChildren > 0) {
                    // An orchestrator handler is awaiting its subtasks: the task is long-running, so
                    // park for the next child event (up to 50ms) instead of counting toward the idle
                    // timeout. The children run on other engine slots and deliver back via deliverChildEvent.
                    if (!deliveredEvent) {
                        PendingChildEvent waited = pollChildEvent(50);
                        if (waited != null) {
                            deliverInboundEvent(globalObject, "__childEvent", waited.json);
                            if (waited.terminal) {
                                outstandingChildren--;
                            }
                            context.evaluate("void 0;");
                        }
                    }
                    idleAttempts = 0;
                }
                else if (deliveredEvent || pumped) {
                    idleAttempts = 0;
                }
                else {
                    idleAttempts++;
                    if (idleAttempts >= 5000) {
                        break;
                    }
                }
            }

            if (errorMessage != null) {
                Log.e(LOG_TAG, "Task " + task.taskId + " failed: " + errorMessage);
                callbacks.onTaskFailed(task, errorMessage);
            }
            else if (outputsJson != null) {
                Log.i(LOG_TAG, "Task " + task.taskId + " succeeded: " + outputsJson);
                callbacks.onTaskSucceeded(task, outputsJson);
            }
            else {
                callbacks.onTaskFailed(task, "Task " + task.taskId + " did not settle.");
            }
        }
        catch (Throwable error) {
            String message = error.getMessage();
            if (message == null) {
                message = error.toString();
            }
            Log.e(LOG_TAG, "Task " + task.taskId + " failed: " + message, error);
            callbacks.onTaskFailed(task, message);
        }
        finally {
            if (hostBridge != null) {
                hostBridge.setCurrentTask(null);
            }
        }
    }

    //
    // Creates the QuickJSContext (if not already created), routes console.log to logcat, installs
    // the no-op timer shims and the host bridge, and evaluates the worker bundle exactly once.
    // Runs on the worker thread.
    //
    private void ensureContext(EngineCallbacks callbacks) throws IOException {
        if (context != null) {
            return;
        }

        context = QuickJSContext.create();
        QuickJSLoader.initConsoleLog(context);
        hostBridge = new HostBridge(callbacks, cancellationState, sessionId, storageRoot);

        // QuickJS lacks setInterval/clearInterval; inject them as no-ops before the bundle.
        context.evaluate("var setInterval = function () { return 0; }; var clearInterval = function () {};");

        // Build globalThis.host with the infrastructure callables and the NOT IMPLEMENTED sha256.
        JSObject host = context.createNewJSObject();
        host.setProperty("platform", HostFunctions.PLATFORM);
        host.setProperty("sessionId", sessionId);
        host.setProperty("sendMessage", (JSCallFunction) args -> {
            hostBridge.sendMessage((String) args[0], (String) args[1]);
            return null;
        });
        host.setProperty("isCancelled", (JSCallFunction) args -> hostBridge.isCancelled((String) args[0]));
        // host.queueTask(childTaskId, type, dataJson, source): enqueue a child task back on the native
        // pool (the mobile "main-thread queue"). Increment the outstanding-children count on this
        // worker thread only after the pool has accepted the child, so the run loop keeps the engine
        // alive while the handler awaits its subtasks.
        host.setProperty("queueTask", (JSCallFunction) args -> safeVoid(() -> {
            hostBridge.queueChildTask((String) args[0], (String) args[1], (String) args[2], (String) args[3]);
            outstandingChildren++;
        }));
        // A native host function must NEVER let a Java exception escape into QuickJS: the wrapper does
        // not convert a thrown Java exception into a JS exception and the process would crash. Every
        // host function below is wrapped so an exception is returned as an error-envelope string the
        // JS fs shim decodes and throws (the boolean fsAccess returns false on error instead).
        host.setProperty("sha256", (JSCallFunction) args -> safeString(() -> hostBridge.sha256((String) args[0])));

        // Native-backed fs read functions: the storage layer (FileStorage over the mobile fs shim)
        // calls these to read a database from the app sandbox. Binary file contents cross as base64
        // strings; stat/readdir results cross as JSON strings; a missing path returns null.
        host.setProperty("fsReadFile", (JSCallFunction) args -> safeString(() -> hostBridge.fsReadFile((String) args[0])));
        host.setProperty("fsAccess", (JSCallFunction) args -> safeBoolean(() -> hostBridge.fsAccess((String) args[0])));
        host.setProperty("fsStat", (JSCallFunction) args -> safeString(() -> hostBridge.fsStat((String) args[0])));
        host.setProperty("fsReaddir", (JSCallFunction) args -> safeString(() -> hostBridge.fsReaddir((String) args[0])));

        // Native-backed fs write functions (create-database, import, save, move, replicate). Bytes
        // arrive as base64 strings; booleans cross directly. They return null on success or an
        // error-envelope string on failure.
        host.setProperty("fsWriteFile", (JSCallFunction) args -> safeVoid(() ->
            hostBridge.fsWriteFile((String) args[0], (String) args[1], toBoolean(args[2]))));
        host.setProperty("fsMkdir", (JSCallFunction) args -> safeVoid(() ->
            hostBridge.fsMkdir((String) args[0], toBoolean(args[1]))));
        host.setProperty("fsRename", (JSCallFunction) args -> safeVoid(() ->
            hostBridge.fsRename((String) args[0], (String) args[1])));
        host.setProperty("fsUnlink", (JSCallFunction) args -> safeVoid(() ->
            hostBridge.fsUnlink((String) args[0])));
        host.setProperty("fsRm", (JSCallFunction) args -> safeVoid(() ->
            hostBridge.fsRm((String) args[0], toBoolean(args[1]), toBoolean(args[2]))));

        // Native-backed TCP socket functions: the embedded asset server (run as a long-lived task)
        // binds a loopback listener and reads/writes connections through these. Inbound connection /
        // data / close events are pushed back into the engine via globalThis.__tcpEvent (see the run
        // loop). They return a string result/error envelope (tcpListen returns the listener JSON);
        // tcpWrite/tcpClose/tcpStopListening return null on success.
        host.setProperty("tcpListen", (JSCallFunction) args -> safeString(() ->
            hostBridge.tcpListen((String) args[0], ((Number) args[1]).intValue())));
        host.setProperty("tcpWrite", (JSCallFunction) args -> safeString(() ->
            hostBridge.tcpWrite((String) args[0], (String) args[1])));
        host.setProperty("tcpClose", (JSCallFunction) args -> safeString(() ->
            hostBridge.tcpClose((String) args[0])));
        host.setProperty("tcpStopListening", (JSCallFunction) args -> safeString(() ->
            hostBridge.tcpStopListening((String) args[0])));

        // Native-backed media tools (host.imageMagick / host.ffmpeg / host.ffprobe): the import,
        // thumbnail, and transcode paths build a JSON argv string and run the bundled tool in-process,
        // getting back a { exitCode, output } JSON string. HostBridge already implements these (added
        // with the native media tools); they are exposed here so the embedded worker can reach them,
        // exactly as the iOS HostBridge installs them.
        host.setProperty("imageMagick", (JSCallFunction) args -> safeString(() ->
            hostBridge.imageMagick((String) args[0])));
        host.setProperty("ffmpeg", (JSCallFunction) args -> safeString(() ->
            hostBridge.ffmpeg((String) args[0])));
        host.setProperty("ffprobe", (JSCallFunction) args -> safeString(() ->
            hostBridge.ffprobe((String) args[0])));

        // Native-backed UDP functions: LAN-share discovery binds a datagram socket and broadcasts /
        // receives through these. Inbound datagrams are pushed into the engine via globalThis.__udpEvent.
        host.setProperty("udpBind", (JSCallFunction) args -> safeString(() ->
            hostBridge.udpBind((String) args[0], ((Number) args[1]).intValue(), toBoolean(args[2]))));
        host.setProperty("udpSend", (JSCallFunction) args -> safeString(() ->
            hostBridge.udpSend((String) args[0], (String) args[1], (String) args[2], ((Number) args[3]).intValue())));
        host.setProperty("udpClose", (JSCallFunction) args -> safeString(() ->
            hostBridge.udpClose((String) args[0])));

        // Native-backed TLS functions: LAN-share's receiver runs a self-signed HTTPS server and its
        // sender connects with certificate pinning through these. Inbound connection / data / close
        // events are pushed into the engine via globalThis.__tlsEvent.
        host.setProperty("tlsListen", (JSCallFunction) args -> safeString(() ->
            hostBridge.tlsListen((String) args[0], ((Number) args[1]).intValue(), (String) args[2], (String) args[3])));
        host.setProperty("tlsConnect", (JSCallFunction) args -> safeString(() ->
            hostBridge.tlsConnect((String) args[0], ((Number) args[1]).intValue())));
        host.setProperty("tlsWrite", (JSCallFunction) args -> safeString(() ->
            hostBridge.tlsWrite((String) args[0], (String) args[1])));
        host.setProperty("tlsClose", (JSCallFunction) args -> safeString(() ->
            hostBridge.tlsClose((String) args[0])));
        host.setProperty("tlsStopListening", (JSCallFunction) args -> safeString(() ->
            hostBridge.tlsStopListening((String) args[0])));

        // Native-backed RSA crypto: LAN-share's receiver generates a key pair and self-signs its TLS
        // certificate through these (SHA-256 hashing stays in pure JS).
        host.setProperty("cryptoGenerateRsaKeyPair", (JSCallFunction) args -> safeString(() ->
            hostBridge.cryptoGenerateRsaKeyPair(((Number) args[0]).intValue())));
        host.setProperty("cryptoSignSha256", (JSCallFunction) args -> safeString(() ->
            hostBridge.cryptoSignSha256((String) args[0], (String) args[1])));

        context.getGlobalObject().setProperty("host", host);

        // Evaluate the bundle once. It installs globalThis.__photosphereWorker.runTask.
        context.evaluate(readBundleAsset(), BUNDLE_ASSET_NAME);
    }

    //
    // Coerces a host-call argument to a primitive boolean. QuickJS passes JS booleans as
    // java.lang.Boolean; anything else (including null/undefined) is treated as false.
    //
    private static boolean toBoolean(Object value) {
        return value instanceof Boolean && (Boolean) value;
    }

    //
    // Runs a string-returning host action, returning its result or, on any throwable, an error
    // envelope string (HostFunctions.hostErrorEnvelope, shared with the JS shim and iOS).
    //
    private static String safeString(Supplier<String> action) {
        try {
            return action.get();
        }
        catch (Throwable error) {
            return HostFunctions.hostErrorEnvelope(error);
        }
    }

    //
    // Runs a boolean-returning host action (existence check), returning false on any throwable.
    //
    private static boolean safeBoolean(BooleanSupplier action) {
        try {
            return action.getAsBoolean();
        }
        catch (Throwable error) {
            return false;
        }
    }

    //
    // Runs a void host action, returning null on success or an error envelope string on any throwable.
    //
    private static String safeVoid(Runnable action) {
        try {
            action.run();
            return null;
        }
        catch (Throwable error) {
            return HostFunctions.hostErrorEnvelope(error);
        }
    }

    //
    // Delivers one inbound TCP event (connection / data / close) JSON into the JS net shim by setting
    // it on a global and invoking globalThis.__tcpEvent. Runs on the worker thread so the QuickJS
    // context is only ever touched here, never from the socket accept/read threads.
    //
    private void deliverTcpEvent(JSObject globalObject, String eventJson) {
        globalObject.setProperty("__tcpEventArg", eventJson);
        context.evaluate("(typeof globalThis.__tcpEvent === 'function') && globalThis.__tcpEvent(globalThis.__tcpEventArg);");
    }

    //
    // Delivers one inbound event JSON into the named JS entry point (globalThis.__udpEvent or
    // globalThis.__tlsEvent) by setting it on a global and invoking the function. Runs on the worker
    // thread so the QuickJS context is only ever touched here, never from the socket callback threads.
    //
    private void deliverInboundEvent(JSObject globalObject, String functionName, String eventJson) {
        globalObject.setProperty("__inboundEventArg", eventJson);
        context.evaluate("(typeof globalThis." + functionName + " === 'function') && globalThis." + functionName + "(globalThis.__inboundEventArg);");
    }

    //
    // Reads the worker bundle asset into a string. Loaded only from the packaged app asset.
    //
    private String readBundleAsset() throws IOException {
        try (InputStream input = androidContext.getAssets().open(BUNDLE_ASSET_NAME)) {
            StringBuilder builder = new StringBuilder();
            try (BufferedReader reader = new BufferedReader(new InputStreamReader(input, StandardCharsets.UTF_8))) {
                char[] buffer = new char[64 * 1024];
                int charsRead = reader.read(buffer);
                while (charsRead != -1) {
                    builder.append(buffer, 0, charsRead);
                    charsRead = reader.read(buffer);
                }
            }
            return builder.toString();
        }
    }

    //
    // Disposes the engine: closes the QuickJSContext on the worker thread (contexts must be
    // destroyed on their owning thread), then shuts the thread down.
    //
    @Override
    public void dispose() {
        if (hostBridge != null) {
            hostBridge.tcp.shutdown();
            hostBridge.udp.shutdown();
            hostBridge.tls.shutdown();
        }
        worker.submit(() -> {
            if (context != null) {
                try {
                    context.destroy();
                }
                catch (Throwable error) {
                    Log.e(LOG_TAG, "Error destroying QuickJSContext.", error);
                }
                finally {
                    context = null;
                }
            }
        });
        worker.shutdown();
    }
}
