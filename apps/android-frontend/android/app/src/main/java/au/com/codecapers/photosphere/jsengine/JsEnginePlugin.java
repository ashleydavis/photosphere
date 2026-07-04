package au.com.codecapers.photosphere.jsengine;

import android.app.Activity;
import android.content.Intent;
import android.database.Cursor;
import android.net.Uri;
import android.provider.OpenableColumns;
import android.util.Log;

import androidx.activity.result.ActivityResult;

import com.getcapacitor.JSArray;
import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.ActivityCallback;
import com.getcapacitor.annotation.CapacitorPlugin;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Deque;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

//
// The Android side of the "JsEngine" Capacitor plugin. It owns the engine pool and bridges
// it to the WebView: addTask is fire-and-forget (enqueue and resolve immediately, the result
// arrives later as a taskCompleted event); cancelTasks cancels by source; shutdown tears the
// pool down. Task outcomes and streamed messages reach the WebView via notifyListeners. As a
// belt-and-suspenders against the startup race where a task could complete before the JS
// listener is registered, events are buffered per-taskId while no listener exists and flushed
// when one registers.
//
@CapacitorPlugin(name = "JsEngine")
public final class JsEnginePlugin extends Plugin {

    //
    // Log tag for plugin diagnostics.
    //
    private static final String LOG_TAG = "JsEnginePlugin";

    //
    // The taskCompleted event name emitted to the WebView.
    //
    private static final String EVENT_TASK_COMPLETED = "taskCompleted";

    //
    // The taskMessage event name emitted to the WebView.
    //
    private static final String EVENT_TASK_MESSAGE = "taskMessage";

    //
    // The TaskStatus string value for a succeeded task (matches packages/task-queue).
    //
    private static final String STATUS_SUCCEEDED = "succeeded";

    //
    // The TaskStatus string value for a failed task (matches packages/task-queue).
    //
    private static final String STATUS_FAILED = "failed";

    //
    // The engine pool that runs tasks. Created lazily on first use so the Android context and
    // storage root are available.
    //
    private EnginePool enginePool;

    //
    // Lock guarding the event buffer and the listener-ready flag.
    //
    private final Object eventLock = new Object();

    //
    // Buffered events, keyed by taskId, held while no JS listener is registered yet and flushed
    // on first listener registration. Each buffered event records its event name and payload.
    //
    private final Map<String, Deque<BufferedEvent>> bufferedEventsByTaskId = new HashMap<>();

    //
    // True once a JS listener has been registered and the buffer has been flushed.
    //
    private boolean listenersReady = false;

    //
    // A buffered taskCompleted / taskMessage event awaiting a registered listener.
    //
    private static final class BufferedEvent {

        //
        // The event name (taskCompleted or taskMessage).
        //
        final String eventName;

        //
        // The event payload.
        //
        final JSObject payload;

        //
        // Constructs a buffered event.
        //
        BufferedEvent(String eventName, JSObject payload) {
            this.eventName = eventName;
            this.payload = payload;
        }
    }

    //
    // Returns the storage root the path-sandbox confines host functions to. For the first slice
    // this is the app's private files directory; plan-mobile-storage-options.md owns the final
    // root choice and the rest of the fs surface.
    //
    private File getStorageRoot() {
        return getContext().getFilesDir();
    }

    //
    // Lazily creates the engine pool, wiring the production QuickJS engine into each slot and
    // the plugin's event emission as the pool listener.
    //
    private synchronized EnginePool ensurePool() {
        if (enginePool != null) {
            return enginePool;
        }

        File storageRoot = getStorageRoot();

        EnginePool.PoolListener poolListener = new EnginePool.PoolListener() {

            //
            // Emits a succeeded taskCompleted event.
            //
            @Override
            public void onTaskSucceeded(PooledTask task, String outputsJson) {
                emitTaskCompleted(task, STATUS_SUCCEEDED, null, outputsJson);
            }

            //
            // Emits a failed taskCompleted event.
            //
            @Override
            public void onTaskFailed(PooledTask task, String errorMessage) {
                emitTaskCompleted(task, STATUS_FAILED, errorMessage, null);
            }

            //
            // Emits a taskMessage event for a streamed progress message.
            //
            @Override
            public void onTaskMessage(PooledTask task, String messageJson) {
                emitTaskMessage(task, messageJson);
            }
        };

        // The pool hands each engine the sessionId and cancellation state it owns, so the engine
        // factory has everything it needs at construction time with no ordering cycle.
        EnginePool.EngineFactory engineFactory =
            (slotIndex, sessionId, cancellationState) -> new QuickJsTaskEngine(
                getContext(),
                cancellationState,
                sessionId,
                storageRoot);

        enginePool = new EnginePool(engineFactory, poolListener);

        return enginePool;
    }

    //
    // addTask: receives { taskId, type, data, source }. Fire-and-forget: enqueue the task and
    // resolve the call immediately. The result is delivered later via the taskCompleted event.
    // data is an arbitrary JSON object passed to the engine as a JSON string.
    //
    @PluginMethod
    public void addTask(PluginCall call) {
        String taskId = call.getString("taskId");
        String type = call.getString("type");
        String source = call.getString("source");

        if (taskId == null || type == null || source == null) {
            call.reject("addTask requires taskId, type, and source.");
            return;
        }

        // data is an arbitrary JSON object; serialise it to a JSON string for the engine.
        String dataJson = "null";
        JSObject data = call.getObject("data");
        if (data != null) {
            dataJson = data.toString();
        }

        PooledTask task = new PooledTask(taskId, type, dataJson, source);
        ensurePool().addTask(task);

        call.resolve();
    }

    //
    // cancelTasks: receives { source }. Adds the source to the cancelled set, drops matching
    // pending tasks, and resolves.
    //
    @PluginMethod
    public void cancelTasks(PluginCall call) {
        String source = call.getString("source");
        if (source == null) {
            call.reject("cancelTasks requires source.");
            return;
        }

        ensurePool().cancelTasks(source);
        call.resolve();
    }

    //
    // pickFiles: opens the native multi-select photo picker for images and videos. Fire-and-await:
    // the picked items are copied into the sandbox and their sandbox-relative paths are returned in
    // the ActivityCallback. Uses ACTION_OPEN_DOCUMENT so the returned content URIs are readable and
    // multi-selection is supported across supported Android versions.
    //
    @PluginMethod
    public void pickFiles(PluginCall call) {
        Intent intent = new Intent(Intent.ACTION_OPEN_DOCUMENT);
        intent.addCategory(Intent.CATEGORY_OPENABLE);
        intent.setType("*/*");
        intent.putExtra(Intent.EXTRA_MIME_TYPES, new String[]{"image/*", "video/*"});
        intent.putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true);

        startActivityForResult(call, intent, "pickFilesResult");
    }

    //
    // Handles the photo picker result: copies each chosen content URI into the sandbox import temp
    // directory and resolves the call with the copied files' sandbox-relative paths. A cancelled pick
    // (no data, non-OK result) resolves with an empty list, matching the frontend "cancelled" contract.
    //
    @ActivityCallback
    private void pickFilesResult(PluginCall call, ActivityResult result) {
        if (call == null) {
            return;
        }

        JSArray paths = new JSArray();
        Intent data = result.getData();

        if (result.getResultCode() != Activity.RESULT_OK || data == null) {
            JSObject response = new JSObject();
            response.put("paths", paths);
            call.resolve(response);
            return;
        }

        try {
            if (data.getClipData() != null) {
                int count = data.getClipData().getItemCount();
                for (int index = 0; index < count; index++) {
                    Uri uri = data.getClipData().getItemAt(index).getUri();
                    paths.put(copyPickedUri(uri));
                }
            }
            else if (data.getData() != null) {
                paths.put(copyPickedUri(data.getData()));
            }
        }
        catch (IOException error) {
            call.reject("Failed to import picked files: " + error.getMessage());
            return;
        }

        JSObject response = new JSObject();
        response.put("paths", paths);
        call.resolve(response);
    }

    //
    // Copies one picked content URI into the sandbox import temp directory under a fresh uuid name and
    // returns its sandbox-relative path (the value the import task scans). The extension is derived from
    // the URI's display name or mime type via ImportPicker.
    //
    private String copyPickedUri(Uri uri) throws IOException {
        String displayName = queryDisplayName(uri);
        String mimeType = getContext().getContentResolver().getType(uri);
        String relativePath = ImportPicker.buildRelativePath(UUID.randomUUID().toString(), displayName, mimeType);

        File destination = new File(getStorageRoot(), relativePath);
        File parent = destination.getParentFile();
        if (parent != null) {
            parent.mkdirs();
        }

        try (InputStream input = getContext().getContentResolver().openInputStream(uri);
             OutputStream output = new FileOutputStream(destination)) {
            if (input == null) {
                throw new IOException("could not open picked file stream");
            }
            byte[] buffer = new byte[64 * 1024];
            int bytesRead = input.read(buffer);
            while (bytesRead != -1) {
                output.write(buffer, 0, bytesRead);
                bytesRead = input.read(buffer);
            }
        }

        return relativePath;
    }

    //
    // Queries the display name for a content URI via the OpenableColumns cursor, or null when it is
    // not available (in which case the extension falls back to the mime type).
    //
    private String queryDisplayName(Uri uri) {
        try (Cursor cursor = getContext().getContentResolver().query(uri, null, null, null, null)) {
            if (cursor != null && cursor.moveToFirst()) {
                int nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME);
                if (nameIndex >= 0) {
                    return cursor.getString(nameIndex);
                }
            }
        }
        return null;
    }

    //
    // shutdown: tears down the pool, disposes contexts, clears the event buffer, and resolves.
    //
    @PluginMethod
    public void shutdown(PluginCall call) {
        synchronized (this) {
            if (enginePool != null) {
                enginePool.shutdown();
                enginePool = null;
            }
        }

        synchronized (eventLock) {
            bufferedEventsByTaskId.clear();
            listenersReady = false;
        }

        call.resolve();
    }

    //
    // Capacitor lifecycle hook invoked when a JS listener is added. Delegates to the base
    // implementation, then flushes any events buffered during the startup race so no completion
    // or message is lost. The RETURN_NONE annotation matches the base method so the call resolves
    // correctly on the JS side.
    //
    @Override
    @PluginMethod(returnType = PluginMethod.RETURN_NONE)
    public void addListener(PluginCall call) {
        super.addListener(call);
        flushBufferedEvents();
    }

    //
    // Builds and emits a taskCompleted event with the contract payload
    // { taskId, result: { taskId, status, errorMessage?, outputs?, type, inputs } }. outputs and
    // inputs are parsed from their JSON strings so the WebView receives real objects, not strings.
    //
    private void emitTaskCompleted(PooledTask task, String status, String errorMessage, String outputsJson) {
        JSObject result = new JSObject();
        result.put("taskId", task.taskId);
        result.put("status", status);
        result.put("type", task.type);

        if (errorMessage != null) {
            result.put("errorMessage", errorMessage);
        }

        if (outputsJson != null) {
            result.put("outputs", parseJsonValue(outputsJson));
        }

        result.put("inputs", parseJsonValue(task.dataJson));

        JSObject payload = new JSObject();
        payload.put("taskId", task.taskId);
        payload.put("result", result);

        dispatchOrBuffer(task.taskId, EVENT_TASK_COMPLETED, payload);
    }

    //
    // Builds and emits a taskMessage event with the contract payload { taskId, message }. The
    // message JSON string is parsed to a real object/value for the WebView.
    //
    private void emitTaskMessage(PooledTask task, String messageJson) {
        JSObject payload = new JSObject();
        payload.put("taskId", task.taskId);
        payload.put("message", parseJsonValue(messageJson));

        dispatchOrBuffer(task.taskId, EVENT_TASK_MESSAGE, payload);
    }

    //
    // Emits the event immediately if a listener is registered; otherwise buffers it per-taskId
    // until the first listener registers and the buffer is flushed.
    //
    private void dispatchOrBuffer(String taskId, String eventName, JSObject payload) {
        synchronized (eventLock) {
            if (listenersReady && hasListeners(eventName)) {
                notifyListeners(eventName, payload);
                return;
            }

            Deque<BufferedEvent> queue = bufferedEventsByTaskId.get(taskId);
            if (queue == null) {
                queue = new ArrayDeque<>();
                bufferedEventsByTaskId.put(taskId, queue);
            }
            queue.addLast(new BufferedEvent(eventName, payload));
        }
    }

    //
    // Flushes every buffered event in insertion order once a listener is registered. Marks
    // listeners ready so subsequent events dispatch directly.
    //
    private void flushBufferedEvents() {
        List<BufferedEvent> toEmit = new ArrayList<>();

        synchronized (eventLock) {
            listenersReady = true;
            for (Deque<BufferedEvent> queue : bufferedEventsByTaskId.values()) {
                toEmit.addAll(queue);
            }
            bufferedEventsByTaskId.clear();
        }

        // Emit outside the lock so notifyListeners never runs while the event lock is held.
        for (BufferedEvent event : toEmit) {
            notifyListeners(event.eventName, event.payload);
        }
    }

    //
    // Parses a JSON string into a value suitable for a JSObject field: an object, an array, or
    // a primitive. Falls back to the raw string if it is not valid JSON, so a malformed payload
    // never crashes event emission.
    //
    private Object parseJsonValue(String json) {
        if (json == null) {
            return JSONObject.NULL;
        }

        String trimmed = json.trim();
        if (trimmed.isEmpty() || trimmed.equals("null")) {
            return JSONObject.NULL;
        }

        try {
            if (trimmed.startsWith("{")) {
                return new JSONObject(trimmed);
            }
            if (trimmed.startsWith("[")) {
                return new JSONArray(trimmed);
            }
            // Wrap a bare primitive so org.json can parse it, then unwrap.
            return new JSONObject("{\"value\":" + trimmed + "}").get("value");
        }
        catch (JSONException error) {
            Log.e(LOG_TAG, "Failed to parse JSON value, passing as raw string: " + error.getMessage());
            return json;
        }
    }

    //
    // Capacitor lifecycle hook: ensure the pool is torn down when the plugin is destroyed so
    // engine threads never outlive the plugin.
    //
    @Override
    protected void handleOnDestroy() {
        synchronized (this) {
            if (enginePool != null) {
                enginePool.shutdown();
                enginePool = null;
            }
        }
        super.handleOnDestroy();
    }
}
