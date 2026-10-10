package au.com.codecapers.photosphere.ziggy;

import android.app.Activity;
import android.content.pm.PackageManager;
import android.os.Build;
import android.util.Log;
import dev.ziggy.shell.HostRequestException;
import dev.ziggy.shell.HostRequestHandler;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

// Photosphere's answers to the core's host requests on Android: the permission prompts, the device keychain, the connection type and
// the things the background work asks of the platform. Each request is named by its method and carries and returns JSON text. The core
// calls from a worker thread and waits, so a request may block on a permission prompt.
public final class PhotosphereHostRequests implements HostRequestHandler {
    // The logcat tag the background work reports under. The background work runs with the app off screen, when the app's own log file
    // (written through the page) is not being written, so what it is doing is told to logcat.
    public static final String BACKGROUND_LOG_TAG = "AutoImportService";

    // The notification permission, which Android 13 made a runtime permission.
    private static final String POST_NOTIFICATIONS = "android.permission.POST_NOTIFICATIONS";

    // The first Android version where notifications need a permission.
    private static final int FIRST_NOTIFICATION_PERMISSION_VERSION = 33;

    private final Activity activity;
    private final PermissionRequester permissions;
    private final NetworkHost network;
    private final BackgroundWakeLock wakeLock;
    private final MediaTools mediaTools;

    // The handlers other code has registered for methods of their own, by method name.
    private final Map<String, HostRequestHandler> registered = new ConcurrentHashMap<String, HostRequestHandler>();

    public PhotosphereHostRequests(Activity activity, PermissionRequester permissions) {
        this.activity = activity;
        this.permissions = permissions;
        this.network = new NetworkHost(activity);
        this.wakeLock = new BackgroundWakeLock(activity);
        this.mediaTools = new MediaTools(activity.getCacheDir());
    }

    // Registers the handler that answers one more method. A method this class answers itself cannot be taken over, and a method
    // registered twice is an error, so two parts of the app cannot answer the same request without one of them knowing.
    public void register(String method, HostRequestHandler handler) {
        if (registered.putIfAbsent(method, handler) != null) {
            throw new IllegalStateException("A handler is already registered for the host request " + method + ".");
        }
    }

    // Gives back everything the background work holds, for when the activity is being destroyed.
    public void release() {
        wakeLock.releaseAll();
    }

    @Override
    public String handle(String method, String requestJson) throws HostRequestException {
        try {
            switch (method) {
                case "requestMediaPermission":
                    return requestMediaPermission();
                case "requestNotificationPermission":
                    return requestNotificationPermission();
                case "networkConnectionType":
                    return JSONObject.quote(network.connectionType());
                case "secureStoreGet":
                    return secureStoreGet(new JSONObject(requestJson).getString("key"));
                case "secureStoreSet":
                    JSONObject toSet = new JSONObject(requestJson);
                    secureStore().set(toSet.getString("key"), toSet.getString("value"));
                    return "null";
                case "secureStoreDelete":
                    secureStore().delete(new JSONObject(requestJson).getString("key"));
                    return "null";
                case "secureStoreKeys":
                    return secureStoreKeys();
                case "holdAwake":
                    wakeLock.hold(new JSONObject(requestJson).getBoolean("awake"));
                    return "null";
                case "runMagick":
                case "runFfmpeg":
                case "runFfprobe":
                    return mediaTools.run(method, requestJson);
                case "backgroundLog":
                    backgroundLog(new JSONObject(requestJson));
                    return "null";
                default:
                    HostRequestHandler other = registered.get(method);
                    if (other != null) {
                        return other.handle(method, requestJson);
                    }
                    throw new HostRequestException("The Photosphere Android app cannot do \"" + method + "\" yet.");
            }
        } catch (JSONException error) {
            throw new HostRequestException("The request " + method + " was not understood: " + error.getMessage(), error);
        }
    }

    private SecureStore secureStore() throws HostRequestException {
        try {
            return SecureStore.forContext(activity);
        } catch (Exception error) {
            throw new HostRequestException("The device keychain could not be opened: " + error.getMessage(), error);
        }
    }

    private String secureStoreGet(String key) throws HostRequestException, JSONException {
        String value = secureStore().get(key);
        return new JSONObject().put("value", value == null ? JSONObject.NULL : value).toString();
    }

    private String secureStoreKeys() throws HostRequestException {
        List<String> keys = secureStore().keys();
        JSONArray array = new JSONArray();
        for (String key : keys) {
            array.put(key);
        }
        try {
            return new JSONObject().put("keys", array).toString();
        } catch (JSONException error) {
            throw new HostRequestException("The keychain's keys could not be written: " + error.getMessage(), error);
        }
    }

    private void backgroundLog(JSONObject request) throws JSONException {
        String message = request.getString("message");
        if (request.getBoolean("error")) {
            Log.e(BACKGROUND_LOG_TAG, message);
        } else {
            Log.i(BACKGROUND_LOG_TAG, message);
        }
    }

    // Asks for the photo library permission and reports what came back, as {granted, partial}. Asked for again when the app holds
    // only the photos the user picked, because that is the one way back to the whole library: the platform puts the choice up again
    // and the user can allow everything this time. A permission the user has refused for good is answered without a dialog, so the
    // request comes back denied rather than waiting for an answer that is never coming.
    private String requestMediaPermission() throws HostRequestException {
        if (currentMediaAccess() != MediaAccess.FULL) {
            ask(MediaPermissions.permissionsForVersion(Build.VERSION.SDK_INT));
        }
        MediaAccess access = currentMediaAccess();
        try {
            return new JSONObject()
                .put("granted", access == MediaAccess.FULL)
                .put("partial", access == MediaAccess.PARTIAL)
                .toString();
        } catch (JSONException error) {
            throw new HostRequestException("The photo permission answer could not be written: " + error.getMessage(), error);
        }
    }

    // Asks for the notification permission, which the foreground service's ongoing notification needs from Android 13, and reports
    // whether it is held as {granted}. The background work starts whatever the answer, because a foreground service without the
    // permission still runs; it is the notification that is missing.
    private String requestNotificationPermission() throws HostRequestException {
        boolean granted = Build.VERSION.SDK_INT < FIRST_NOTIFICATION_PERMISSION_VERSION || isGranted(POST_NOTIFICATIONS);
        if (!granted) {
            ask(new String[] { POST_NOTIFICATIONS });
            granted = isGranted(POST_NOTIFICATIONS);
        }
        try {
            return new JSONObject().put("granted", granted).toString();
        } catch (JSONException error) {
            throw new HostRequestException("The notification permission answer could not be written: " + error.getMessage(), error);
        }
    }

    private void ask(String[] permissionNames) throws HostRequestException {
        try {
            if (!permissions.request(permissionNames)) {
                throw new HostRequestException("The app closed before the permission was answered.");
            }
        } catch (InterruptedException interrupted) {
            Thread.currentThread().interrupt();
            throw new HostRequestException("The permission request was interrupted.", interrupted);
        }
    }

    // How much of the photo library the app can see right now.
    private MediaAccess currentMediaAccess() {
        return MediaAccessChecker.current(activity);
    }

    private boolean isGranted(String permission) {
        return activity.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED;
    }
}
