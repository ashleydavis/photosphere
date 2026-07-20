package au.com.codecapers.photosphere.jsengine;

import android.content.Context;

//
// The process-wide device keychain behind the host.secureStore* functions the embedded worker calls.
// The worker vault reads secret values natively through these so secrets never transit task payloads or
// the log. The store is built lazily from the application context and shared across every engine in the
// pool (EncryptedSharedPreferences with a fixed file name resolves to one underlying store, so this and
// the SecureStore Capacitor plugin read and write the same encrypted secrets).
//
// All methods are static and synchronised on this class: engine threads may call them concurrently, and
// the underlying EncryptedSharedPreferences is itself thread-safe.
//
public final class SecureStoreHost {

    //
    // The lazily-initialised keychain-backed store, or null until initialize() runs.
    //
    private static SecureStore store;

    //
    // Private constructor: static holder, never instantiated.
    //
    private SecureStoreHost() {
    }

    //
    // Builds the keychain-backed store from the application context if it has not been built yet. Called
    // by the engine before it installs the host bridge, so host.secureStore* is ready before any task
    // runs. Idempotent.
    //
    public static synchronized void initialize(Context context) throws Exception {
        if (store == null) {
            store = SecureStore.forContext(context.getApplicationContext());
        }
    }

    //
    // Overrides the backing store. Package-visible for unit tests that drive the host functions against
    // an in-memory SecureStore without an Android context.
    //
    static synchronized void setStoreForTest(SecureStore testStore) {
        store = testStore;
    }

    //
    // Returns the initialised store or throws if it was never initialised (a programming error: the
    // engine initialises it before installing the host bridge).
    //
    private static synchronized SecureStore require() {
        if (store == null) {
            throw new IllegalStateException("SecureStoreHost.initialize was not called before use.");
        }
        return store;
    }

    //
    // host.secureStoreGet(key): returns the stored secret value, or null when absent.
    //
    public static synchronized String secureStoreGet(String key) {
        return require().get(key);
    }

    //
    // host.secureStoreSet(key, value): stores (or overwrites) a secret value.
    //
    public static synchronized void secureStoreSet(String key, String value) {
        require().set(key, value);
    }

    //
    // host.secureStoreDelete(key): deletes a secret (a missing key is not an error).
    //
    public static synchronized void secureStoreDelete(String key) {
        require().delete(key);
    }
}
