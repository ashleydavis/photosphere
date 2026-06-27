package au.com.codecapers.photosphere.jsengine;

import android.util.Log;

import java.io.File;

//
// Static helpers shared by the host bridge across all engine contexts. This plan delivers the
// background-task INFRASTRUCTURE only: it does not implement any native version of a Node.js
// function. The only genuinely native piece here is the NOT IMPLEMENTED loud-failure helper.
// Every host function backed by a Node.js capability (hashing, fs, media) reports NOT IMPLEMENTED
// until a later plan implements it. These helpers are stateless and thread-safe so the pool can
// call them concurrently from multiple engine threads.
//
public final class HostFunctions {

    //
    // Log tag used for all native host-function diagnostics.
    //
    private static final String LOG_TAG = "JsEngineHost";

    //
    // The platform string handed to the embedded worker as host.platform.
    //
    public static final String PLATFORM = "android";

    //
    // Private constructor: static helper class, never instantiated.
    //
    private HostFunctions() {
    }

    //
    // Builds the exact, verbatim NOT IMPLEMENTED error message for a host function that native
    // has not implemented yet, logs it at error level so it is visible during native debugging,
    // and returns a RuntimeException carrying that message so callers can throw it. The message
    // format is contractually identical to the iOS side and the JS-side stubs: changing it breaks
    // the loud-failure guarantee.
    //
    public static RuntimeException notImplemented(String name) {
        String message = "NOT IMPLEMENTED: native host function \"" + name
            + "\" is not implemented yet on " + PLATFORM + ". Implement it ASAP.";
        Log.e(LOG_TAG, message);
        return new RuntimeException(message);
    }

    //
    // host.sha256(path): hashing a file is a Node.js crypto capability that this infrastructure
    // plan deliberately does not implement natively. It reports NOT IMPLEMENTED until a later plan
    // provides the native hashing host function. The arguments are accepted only so the host-bridge
    // signature stays stable for when the real implementation lands.
    //
    public static String sha256(File storageRoot, String candidatePath) {
        throw notImplemented("sha256");
    }
}
