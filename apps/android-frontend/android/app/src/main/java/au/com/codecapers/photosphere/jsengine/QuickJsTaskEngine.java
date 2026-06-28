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
    // The body that runs on the dedicated worker thread: ensures the context exists, points the
    // host bridge at the current task, drives the embedded runTask, drains the returned promise
    // to a JSON result string, and reports it. Any thrown error becomes an onTaskFailed callback
    // so the task fails loudly (including the NOT IMPLEMENTED case).
    //
    private void runTaskOnWorkerThread(PooledTask task, EngineCallbacks callbacks) {
        try {
            ensureContext(callbacks);
            hostBridge.setCurrentTask(task);

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
            for (int attempt = 0; attempt < 5000; attempt++) {
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
                // (retry backoff, timeout guards) can happen. Returns false when no timers remain.
                context.evaluate("globalThis.__ptPumped = (typeof globalThis.__pumpTimers === 'function') ? globalThis.__pumpTimers() : false;");
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
