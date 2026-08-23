package au.com.codecapers.photosphere.jsengine;

import android.app.Activity;
import android.content.Intent;
import android.database.Cursor;
import android.net.Uri;
import android.provider.DocumentsContract;
import android.provider.OpenableColumns;
import android.util.Log;

import androidx.activity.result.ActivityResult;

import com.getcapacitor.JSArray;
import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.PermissionState;
import com.getcapacitor.annotation.ActivityCallback;
import com.getcapacitor.annotation.CapacitorPlugin;
import com.getcapacitor.annotation.Permission;
import com.getcapacitor.annotation.PermissionCallback;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.io.File;
import java.io.FileInputStream;
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
// The photo library permissions are declared here, as aliases, because that is how Capacitor asks
// for a permission and how it delivers the answer back. Requesting straight through
// ActivityCompat.requestPermissions instead looks like it works and does not: the result goes to the
// Activity, and Capacitor only forwards it to the plugin it believes made the request, so a request
// it never saw is answered into nothing and the call waits forever. There are two aliases because
// Android 13 split the storage permission into per-type media ones and an alias names a fixed list,
// so the version decides which one is asked for.
@CapacitorPlugin(
    name = "JsEngine",
    permissions = {
        @Permission(
            alias = MediaPermissions.PER_TYPE_MEDIA_ALIAS,
            strings = { MediaPermissions.READ_MEDIA_IMAGES, MediaPermissions.READ_MEDIA_VIDEO }
        ),
        @Permission(
            alias = MediaPermissions.LEGACY_STORAGE_ALIAS,
            strings = { MediaPermissions.READ_EXTERNAL_STORAGE }
        ),
    }
)
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
    // Returns the storage root the path-sandbox confines host functions to: the app's private
    // files directory.
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
    // addTask: receives { taskId, type, data, source, priority }. Fire-and-forget: enqueue the task
    // and resolve the call immediately. The result is delivered later via the taskCompleted event.
    // data is an arbitrary JSON object passed to the engine as a JSON string. priority is optional
    // and says the user is waiting on this one; an unrecognised value rejects the call rather than
    // quietly running the task in the background.
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

        TaskPriority priority;
        try {
            priority = TaskPriority.fromWireName(call.getString("priority"));
        }
        catch (IllegalArgumentException error) {
            call.reject(error.getMessage());
            return;
        }

        PooledTask task = new PooledTask(taskId, type, dataJson, source, priority);
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
    // Capacitor lifecycle hook invoked once when the plugin loads. Sweeps the export temp directory
    // so any decrypted copy orphaned by a process kill mid-sheet (which skips the completion handler)
    // is collected on the next launch rather than accumulating in app-private storage.
    //
    @Override
    public void load() {
        super.load();
        ExportTemp.sweep(getStorageRoot());

        // Registers what can present the system delete confirmation for removing photos from the
        // device library. The engines that ask for a deletion run on background threads with no
        // Activity of their own, so they read it from here.
        MediaDeleteBroker.register(new MediaLibraryHost.DeleteRequester() {
            @Override
            public boolean requestDelete(List<Uri> itemUris) {
                return requestMediaDelete(itemUris);
            }
        });
    }

    //
    // Presents the system confirmation for deleting the given library items, and blocks the calling
    // engine thread until the user answers.
    //
    // Blocking is deliberate: the host function it serves is synchronous, because everything across
    // the engine bridge is. The wait is bounded, so a dialog that never comes back (the app being
    // backgrounded, say) fails as "not deleted" rather than holding an engine thread forever.
    //
    private boolean requestMediaDelete(List<Uri> itemUris) {
        if (android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.R) {
            // Before Android 11 an app with the storage permission may delete media directly, and
            // there is no system confirmation to present.
            int deleted = 0;
            for (Uri itemUri : itemUris) {
                deleted += getContext().getContentResolver().delete(itemUri, null, null);
            }
            return deleted == itemUris.size();
        }

        android.app.PendingIntent pendingIntent =
            android.provider.MediaStore.createDeleteRequest(getContext().getContentResolver(), itemUris);

        final java.util.concurrent.CountDownLatch answered = new java.util.concurrent.CountDownLatch(1);
        final boolean[] wasDeleted = new boolean[] { false };

        mediaDeleteAnswer = new MediaDeleteAnswer(answered, wasDeleted);

        try {
            getActivity().startIntentSenderForResult(
                pendingIntent.getIntentSender(), MEDIA_DELETE_REQUEST_CODE, null, 0, 0, 0);
        }
        catch (android.content.IntentSender.SendIntentException error) {
            Log.e(LOG_TAG, "Could not present the delete confirmation", error);
            mediaDeleteAnswer = null;
            return false;
        }

        try {
            if (!answered.await(MEDIA_DELETE_TIMEOUT_SECONDS, java.util.concurrent.TimeUnit.SECONDS)) {
                Log.e(LOG_TAG, "The delete confirmation was never answered");
                return false;
            }
        }
        catch (InterruptedException error) {
            Thread.currentThread().interrupt();
            return false;
        }
        finally {
            mediaDeleteAnswer = null;
        }

        return wasDeleted[0];
    }

    //
    // The request code the delete confirmation is answered under.
    //
    private static final int MEDIA_DELETE_REQUEST_CODE = 9318;

    //
    // How long to wait for the user to answer the delete confirmation before giving up on it.
    //
    private static final int MEDIA_DELETE_TIMEOUT_SECONDS = 120;

    //
    // What a waiting delete request is answered through.
    //
    private static final class MediaDeleteAnswer {
        // Released once the user has answered.
        final java.util.concurrent.CountDownLatch answered;

        // Set to the answer before the latch is released.
        final boolean[] wasDeleted;

        MediaDeleteAnswer(java.util.concurrent.CountDownLatch answered, boolean[] wasDeleted) {
            this.answered = answered;
            this.wasDeleted = wasDeleted;
        }
    }

    //
    // The delete request currently waiting on an answer, or null when none is.
    //
    private volatile MediaDeleteAnswer mediaDeleteAnswer;

    //
    // Hands the user's answer to the delete confirmation back to the engine thread waiting on it.
    //
    @Override
    protected void handleOnActivityResult(int requestCode, int resultCode, Intent data) {
        super.handleOnActivityResult(requestCode, resultCode, data);

        if (requestCode != MEDIA_DELETE_REQUEST_CODE) {
            return;
        }

        MediaDeleteAnswer answer = mediaDeleteAnswer;
        if (answer == null) {
            return;
        }

        answer.wasDeleted[0] = resultCode == Activity.RESULT_OK;
        answer.answered.countDown();
    }

    //
    // exportFile: hands one finished sandbox file out of the app. The download task has already
    // written the bytes at { path }; this presents ACTION_CREATE_DOCUMENT so the user chooses a
    // destination, copies the bytes there, and deletes the temp copy on every exit. Resolves
    // { path } on success and { path: null } when the user cancels. A testOutcome short-circuits the
    // sheet (which cannot be dismissed by an automated test) straight to the completion path.
    //
    @PluginMethod
    public void exportFile(PluginCall call) {
        String path = call.getString("path");
        if (path == null) {
            call.reject("exportFile requires a path.");
            return;
        }

        // Confirm the temp file is inside the sandbox before presenting anything.
        File tempFile;
        try {
            tempFile = PathSandbox.resolveWithin(getStorageRoot(), path);
        }
        catch (SecurityException error) {
            call.reject("exportFile: " + error.getMessage());
            return;
        }

        String testOutcome = call.getString("testOutcome");
        if (testOutcome != null) {
            resolveExportFile(call, path, testOutcome.equals("cancelled"));
            return;
        }

        Intent intent = new Intent(Intent.ACTION_CREATE_DOCUMENT);
        intent.addCategory(Intent.CATEGORY_OPENABLE);
        intent.setType("*/*");
        intent.putExtra(Intent.EXTRA_TITLE, tempFile.getName());
        startActivityForResult(call, intent, "exportFileResult");
    }

    //
    // Handles the ACTION_CREATE_DOCUMENT result for a single-file export: on a chosen destination,
    // copies the sandbox temp file's bytes into it; on cancel (RESULT_CANCELED, no data) it skips the
    // copy. Either way the temp copy is deleted and the call resolved with the path or null.
    //
    @ActivityCallback
    private void exportFileResult(PluginCall call, ActivityResult result) {
        if (call == null) {
            return;
        }

        String path = call.getString("path");
        boolean cancelled = result.getResultCode() != Activity.RESULT_OK
            || result.getData() == null
            || result.getData().getData() == null;

        if (!cancelled) {
            try {
                copyTempToDestination(path, result.getData().getData());
            }
            catch (IOException error) {
                // Error exit: still delete the temp copy, then report the failure.
                ExportTemp.finishExport(getStorageRoot(), path, true);
                call.reject("exportFile: failed to write destination: " + error.getMessage());
                return;
            }
        }

        resolveExportFile(call, path, cancelled);
    }

    //
    // exportFiles: hands several finished sandbox files out of the app. Presents
    // ACTION_OPEN_DOCUMENT_TREE so the user chooses a destination folder; each temp file is copied
    // into it and then deleted. Resolves { paths } on success and { paths: null } on cancel.
    //
    @PluginMethod
    public void exportFiles(PluginCall call) {
        List<String> paths = readPaths(call);
        if (paths == null) {
            call.reject("exportFiles requires a paths array.");
            return;
        }

        // Confirm every temp file is inside the sandbox before presenting anything.
        try {
            for (String relativePath : paths) {
                PathSandbox.resolveWithin(getStorageRoot(), relativePath);
            }
        }
        catch (SecurityException error) {
            call.reject("exportFiles: " + error.getMessage());
            return;
        }

        String testOutcome = call.getString("testOutcome");
        if (testOutcome != null) {
            resolveExportFiles(call, paths, testOutcome.equals("cancelled"));
            return;
        }

        Intent intent = new Intent(Intent.ACTION_OPEN_DOCUMENT_TREE);
        startActivityForResult(call, intent, "exportFilesResult");
    }

    //
    // Handles the ACTION_OPEN_DOCUMENT_TREE result for a batch export: on a chosen folder, copies each
    // sandbox temp file into it as a new document; on cancel it skips the copy. Either way every temp
    // copy is deleted and the call resolved with the paths or null.
    //
    @ActivityCallback
    private void exportFilesResult(PluginCall call, ActivityResult result) {
        if (call == null) {
            return;
        }

        List<String> paths = readPaths(call);
        boolean cancelled = result.getResultCode() != Activity.RESULT_OK
            || result.getData() == null
            || result.getData().getData() == null;

        if (!cancelled && paths != null) {
            try {
                copyTempsIntoTree(paths, result.getData().getData());
            }
            catch (IOException error) {
                ExportTemp.finishExportBatch(getStorageRoot(), paths, true);
                call.reject("exportFiles: failed to write destination: " + error.getMessage());
                return;
            }
        }

        resolveExportFiles(call, paths, cancelled);
    }

    //
    // Copies one sandbox temp file's bytes into a chosen content:// destination and closes both
    // streams. The temp file is resolved through PathSandbox so a hostile path cannot escape the root.
    //
    private void copyTempToDestination(String relativePath, Uri destination) throws IOException {
        File source = PathSandbox.resolveWithin(getStorageRoot(), relativePath);
        try (InputStream input = new FileInputStream(source);
             OutputStream output = getContext().getContentResolver().openOutputStream(destination)) {
            if (output == null) {
                throw new IOException("could not open destination stream");
            }
            ExportTemp.copyStream(input, output);
        }
    }

    //
    // Copies each sandbox temp file into the user's chosen document tree as a new document, keeping
    // each file's own name.
    //
    private void copyTempsIntoTree(List<String> relativePaths, Uri treeUri) throws IOException {
        Uri documentTreeUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, DocumentsContract.getTreeDocumentId(treeUri));
        for (String relativePath : relativePaths) {
            File source = PathSandbox.resolveWithin(getStorageRoot(), relativePath);
            Uri created = DocumentsContract.createDocument(getContext().getContentResolver(), documentTreeUri, "application/octet-stream", source.getName());
            if (created == null) {
                throw new IOException("could not create destination document for " + source.getName());
            }
            copyTempToDestination(relativePath, created);
        }
    }

    //
    // Reads the { paths } string array from a call, or null when it is absent or malformed.
    //
    private List<String> readPaths(PluginCall call) {
        JSArray pathsArray = call.getArray("paths");
        if (pathsArray == null) {
            return null;
        }
        try {
            return pathsArray.toList();
        }
        catch (JSONException error) {
            return null;
        }
    }

    //
    // Deletes the single temp copy and resolves the call with { path } (or { path: null } on cancel).
    //
    private void resolveExportFile(PluginCall call, String path, boolean cancelled) {
        String exported = ExportTemp.finishExport(getStorageRoot(), path, cancelled);
        JSObject response = new JSObject();
        response.put("path", exported == null ? JSONObject.NULL : exported);
        call.resolve(response);
    }

    //
    // Deletes every temp copy and resolves the call with { paths } (or { paths: null } on cancel).
    //
    private void resolveExportFiles(PluginCall call, List<String> paths, boolean cancelled) {
        List<String> exported = ExportTemp.finishExportBatch(getStorageRoot(), paths == null ? new ArrayList<>() : paths, cancelled);
        JSObject response = new JSObject();
        if (exported == null) {
            response.put("paths", JSONObject.NULL);
        }
        else {
            JSArray exportedArray = new JSArray();
            for (String exportedPath : exported) {
                exportedArray.put(exportedPath);
            }
            response.put("paths", exportedArray);
        }
        call.resolve(response);
    }

    //
    // requestMediaPermission: asks for the photo library permission and reports whether it was
    // granted, as { granted: boolean }.
    //
    // Android 13 split the old storage permission into per-type media ones, so which permission to
    // ask for depends on the version the app is running on, not the one it was built against.
    //
    @PluginMethod
    public void requestMediaPermission(PluginCall call) {
        String alias = MediaPermissions.aliasForVersion(android.os.Build.VERSION.SDK_INT);

        if (getPermissionState(alias) == PermissionState.GRANTED) {
            resolveMediaPermission(call, alias);
            return;
        }

        requestPermissionForAlias(alias, call, "mediaPermissionCallback");
    }

    //
    // Reports the photo library permission answer back to the call that asked for it.
    //
    // A permission the user has refused for good is answered here without a dialog, which is what a
    // refusal has to look like: the call comes back denied rather than waiting for an answer that is
    // never coming.
    //
    @PermissionCallback
    private void mediaPermissionCallback(PluginCall call) {
        resolveMediaPermission(call, MediaPermissions.aliasForVersion(android.os.Build.VERSION.SDK_INT));
    }

    //
    // Resolves a photo library permission call with what the platform says about the alias.
    //
    // Granted means every permission in the alias was granted, which is what Capacitor reports:
    // automatic import reads both images and videos, and a half-granted answer would silently back
    // up only half the library.
    //
    private void resolveMediaPermission(PluginCall call, String alias) {
        JSObject result = new JSObject();
        result.put("granted", getPermissionState(alias) == PermissionState.GRANTED);
        call.resolve(result);
    }

    //
    // stageMediaDeleteOutcome: stages the answer to the next photo library delete request, instead
    // of presenting the system confirmation.
    //
    // The confirmation cannot be tapped by an automated test, and its wording and controls change
    // between Android versions. Staging the answer leaves everything above the dialog under test:
    // choosing which photos are confirmed, batching them into one request, and handling both
    // answers. Nothing stages an outcome in production, so the real request is issued.
    //
    @PluginMethod
    public void stageMediaDeleteOutcome(PluginCall call) {
        String outcome = call.getString("outcome");
        if (outcome == null) {
            call.reject("outcome is required");
            return;
        }

        MediaDeleteBroker.stageOutcome("deleted".equals(outcome));
        Log.i(LOG_TAG, "Staged the next photo library delete request as \"" + outcome + "\"");
        call.resolve();
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
