package au.com.codecapers.photosphere.jsengine;

import android.util.Log;

import com.getcapacitor.JSArray;
import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;

import org.json.JSONObject;

import java.util.List;

//
// The "SecureStore" Capacitor plugin: the WebView-facing half of the device keychain. The mobile config
// store holds secrets here (via get/set/delete) instead of in plaintext localStorage, matching desktop's
// OS keychain. Backed by SecureStore over EncryptedSharedPreferences, the same encrypted store the
// host.secureStore* functions use, so a secret written from the WebView is readable by the worker vault.
//
// Every method runs on the bridge's background executor rather than the main thread: each one performs
// synchronous encrypted disk I/O (EncryptedSharedPreferences commits the whole file per write) and the
// first call may build the Keystore-backed master key. On the main thread that blocks the WebView, so
// rendering and the smoke-test driver stall behind a secret read.
//
@CapacitorPlugin(name = "SecureStore")
public final class SecureStorePlugin extends Plugin {

    //
    // Log tag for plugin diagnostics.
    //
    private static final String LOG_TAG = "SecureStorePlugin";

    //
    // The keychain-backed store, created lazily on first use (and eagerly on load).
    //
    private SecureStore store;

    //
    // Capacitor lifecycle hook: build the encrypted store up front so the first get/set is fast. A
    // failure here is logged; store() rebuilds lazily on the next call so a transient failure recovers.
    //
    @Override
    public void load() {
        // Off the main thread: building the store touches the AndroidKeyStore and writes the encrypted
        // preferences file, and it retries with a backoff when the keystore is transiently busy. Doing
        // that on the main thread stalls the WebView for as long as it takes, which showed up as the app
        // going silent mid-test. store() rebuilds lazily if this fails, so a transient failure recovers.
        getBridge().execute(() -> {
            try {
                // Through store() so the field is only ever assigned under this plugin's monitor.
                store();
            }
            catch (Exception error) {
                Log.e(LOG_TAG, "Failed to initialise secure store on load: " + error.getMessage());
            }
        });
    }

    //
    // Returns the store, building it lazily if load() failed or has not run. Synchronised because the
    // plugin methods run on the bridge's background executor and can therefore overlap.
    //
    private synchronized SecureStore store() throws Exception {
        if (store == null) {
            store = SecureStore.forContext(getContext());
        }
        return store;
    }

    //
    // get({ key }): resolves { value } with the stored value, or null when the key is absent.
    //
    @PluginMethod
    public void get(PluginCall call) {
        String key = call.getString("key");
        if (key == null) {
            call.reject("get requires key.");
            return;
        }

        getBridge().execute(() -> {
            try {
                String value = store().get(key);
                JSObject response = new JSObject();
                response.put("value", value == null ? JSONObject.NULL : value);
                call.resolve(response);
            }
            catch (Exception error) {
                call.reject("SecureStore get failed: " + error.getMessage());
            }
        });
    }

    //
    // set({ key, value }): stores (or overwrites) the value.
    //
    @PluginMethod
    public void set(PluginCall call) {
        String key = call.getString("key");
        String value = call.getString("value");
        if (key == null || value == null) {
            call.reject("set requires key and value.");
            return;
        }

        getBridge().execute(() -> {
            try {
                store().set(key, value);
                call.resolve();
            }
            catch (Exception error) {
                call.reject("SecureStore set failed: " + error.getMessage());
            }
        });
    }

    //
    // delete({ key }): removes the key (a missing key is not an error).
    //
    @PluginMethod
    public void delete(PluginCall call) {
        String key = call.getString("key");
        if (key == null) {
            call.reject("delete requires key.");
            return;
        }

        getBridge().execute(() -> {
            try {
                store().delete(key);
                call.resolve();
            }
            catch (Exception error) {
                call.reject("SecureStore delete failed: " + error.getMessage());
            }
        });
    }

    //
    // keys(): resolves { keys } with every stored key.
    //
    @PluginMethod
    public void keys(PluginCall call) {
        getBridge().execute(() -> {
            try {
                List<String> keys = store().keys();
                JSArray array = new JSArray();
                for (String key : keys) {
                    array.put(key);
                }
                JSObject response = new JSObject();
                response.put("keys", array);
                call.resolve(response);
            }
            catch (Exception error) {
                call.reject("SecureStore keys failed: " + error.getMessage());
            }
        });
    }
}
