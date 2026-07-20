package au.com.codecapers.photosphere.jsengine;

import android.content.Context;
import android.content.SharedPreferences;

import androidx.security.crypto.EncryptedSharedPreferences;
import androidx.security.crypto.MasterKeys;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Set;

//
// The device keychain behind both the SecureStore Capacitor plugin (WebView) and the host.secureStore*
// functions (embedded worker). It stores mobile secrets encrypted at rest so they match desktop's OS
// keychain instead of sitting in plaintext WebView localStorage.
//
// The storage logic is written against a small Backing interface so it is unit-testable on a plain JVM
// with an in-memory backing (matching the CryptoHost convention). Production uses forContext(), which
// backs it with Android Jetpack Security EncryptedSharedPreferences: keys and values are encrypted with
// a master key held in the hardware-backed Android Keystore (minSdk 24, so API 23+ is always available).
//
public final class SecureStore {

    //
    // The name of the encrypted shared-preferences file the production backing stores items in.
    //
    private static final String PREFS_FILE_NAME = "photosphere_secure_store";

    //
    // Key of a dummy entry committed synchronously when the store is created, purely to force the Tink
    // keyset to disk (see the comment in forContext). Hidden from keys() so it never looks like a
    // stored secret.
    //
    private static final String KEYSET_SENTINEL_KEY = "__photosphere_keyset_sentinel__";

    //
    // The process-wide store over the fixed encrypted-preferences file, built once by forContext() and
    // shared by every caller. Both the SecureStore Capacitor plugin (WebView/main thread) and
    // SecureStoreHost (QuickJS engine worker threads) back onto this one file, and
    // EncryptedSharedPreferences is NOT safe to create concurrently over the same file: two racing
    // EncryptedSharedPreferences.create() calls re-initialise the Tink keyset, so a value written under
    // one keyset can no longer be decrypted and reads back empty (a secret then does not survive an app
    // restart). Building a single instance once, under the class monitor, removes that race.
    //
    private static SecureStore sharedInstance;

    //
    // How many times forContext() tries to build the EncryptedSharedPreferences store before giving up.
    // The AndroidKeyStore that holds the master key can transiently fail to serve/decrypt the key when
    // several app processes start in quick succession: observed under the full mobile smoke-test run,
    // where a relaunched process could not decrypt the existing (durably written) keyset, so a secret
    // that IS on disk read back empty and did not appear to survive the restart. Retrying a few times
    // rides over that transient keystore contention. On a single-test run (no load) the first attempt
    // already succeeds, which is why the failure only showed up in the full suite.
    //
    private static final int CREATE_MAX_ATTEMPTS = 6;

    //
    // The delay between store-creation attempts, in milliseconds. The read happens at app startup before
    // the UI renders, so a few hundred milliseconds of retry is invisible to the user and to the test
    // (which waits for the page to load before it reads the secret).
    //
    private static final long CREATE_RETRY_DELAY_MS = 150;

    //
    // Builds a SecureStore. Separated behind an interface so createWithRetry() is unit-testable with a
    // fake creator: the real creator touches the AndroidKeyStore/EncryptedSharedPreferences, which are
    // not available on a plain JVM.
    //
    public interface StoreCreator {

        // Creates the store, or throws when the underlying secure hardware/keyset is transiently
        // unavailable (the case retrying rides over).
        SecureStore create() throws Exception;
    }

    //
    // The persistence layer the store reads and writes. Abstracted so unit tests can supply an
    // in-memory implementation and production can supply an EncryptedSharedPreferences-backed one.
    //
    public interface Backing {

        // Returns the stored string for a key, or null when the key is absent.
        String getString(String key);

        // Stores (or overwrites) a string for a key.
        void putString(String key, String value);

        // Removes a key. A missing key is not an error.
        void remove(String key);

        // Returns every stored key.
        Set<String> keys();
    }

    //
    // The persistence layer this store delegates to.
    //
    private final Backing backing;

    //
    // Constructs a store over the given backing.
    //
    public SecureStore(Backing backing) {
        this.backing = backing;
    }

    //
    // Returns the process-wide store backed by EncryptedSharedPreferences (Android Keystore-backed),
    // building it once on first use. Synchronised and cached so the plugin and the worker host share one
    // EncryptedSharedPreferences over the file rather than each creating its own (concurrent creation
    // corrupts the Tink keyset and loses data). The application context is used so the singleton never
    // holds a shorter-lived Activity/Bridge context.
    //
    public static synchronized SecureStore forContext(Context context) throws Exception {
        if (sharedInstance == null) {
            // The application context is captured so the retried creator never holds a shorter-lived
            // Activity/Bridge context.
            final Context applicationContext = context.getApplicationContext();

            // Build under a bounded retry so a transient AndroidKeyStore failure (the master key briefly
            // unavailable under process-startup load) does not surface as a lost secret. sharedInstance is
            // assigned only on success, so a total failure leaves it null and the next call retries fresh.
            sharedInstance = createWithRetry(() -> {
                // security-crypto 1.0.0 (stable): MasterKeys creates/looks up the Keystore-held
                // AES-256-GCM master key and returns its alias, which EncryptedSharedPreferences.create takes.
                String masterKeyAlias = MasterKeys.getOrCreate(MasterKeys.AES256_GCM_SPEC);

                SharedPreferences preferences = EncryptedSharedPreferences.create(
                    PREFS_FILE_NAME,
                    masterKeyAlias,
                    applicationContext,
                    EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                    EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM);

                // Force the Tink keyset to disk synchronously. EncryptedSharedPreferences generates the
                // keyset on first use and persists it with SharedPreferences.apply(), which flushes on a
                // background thread. `adb shell am force-stop` SIGKILLs the process without running
                // Android's normal QueuedWork flush, so a newly generated keyset can be lost even though
                // the secret itself was written with a synchronous commit(). The next launch then finds
                // no keyset, generates a fresh one, and every existing entry becomes unreachable: key
                // names are encrypted deterministically, so the lookup silently misses and the secret
                // reads back absent with NO error (which is what "loaded 0 of 1" would mean). Committing
                // a sentinel persists the entire preferences map, keyset included, before the process can
                // be killed. Android rewrites the whole file on any commit, so one small write is enough.
                preferences.edit().putString(KEYSET_SENTINEL_KEY, "1").commit();

                return new SecureStore(new SharedPreferencesBacking(preferences));
            }, CREATE_MAX_ATTEMPTS, CREATE_RETRY_DELAY_MS);
        }

        return sharedInstance;
    }

    //
    // Builds a store using the given creator, retrying on failure up to maxAttempts with a fixed backoff
    // between tries. A transient AndroidKeyStore failure (the master key temporarily unavailable when
    // many processes start at once) throws from EncryptedSharedPreferences.create; retrying rides over it
    // so a durably written secret is still readable after a restart. The last failure is rethrown when
    // every attempt fails, so a genuine, persistent failure is still loud rather than silently swallowed.
    //
    static SecureStore createWithRetry(StoreCreator creator, int maxAttempts, long backoffMillis) throws Exception {
        Exception lastError = null;
        for (int attempt = 1; attempt <= maxAttempts; attempt++) {
            try {
                return creator.create();
            }
            catch (Exception error) {
                lastError = error;
                if (attempt < maxAttempts) {
                    try {
                        Thread.sleep(backoffMillis);
                    }
                    catch (InterruptedException interrupted) {
                        // Preserve the interrupt and stop retrying: fail with the original error.
                        Thread.currentThread().interrupt();
                        throw error;
                    }
                }
            }
        }

        throw lastError;
    }

    //
    // Returns the stored value for a key, or null when absent.
    //
    public String get(String key) {
        return backing.getString(key);
    }

    //
    // Stores (or overwrites) a value for a key.
    //
    public void set(String key, String value) {
        backing.putString(key, value);

        // Read the value straight back. If the store is in a state where an entry that was just written
        // cannot be read again, fail HERE, at the write, rather than letting the loss surface much later
        // as a secret that mysteriously did not survive a restart. That state is reachable: if the Tink
        // keyset is ever regenerated, existing entries become unreachable, and because key names are
        // encrypted deterministically the lookup silently misses instead of raising an error.
        String readBack = backing.getString(key);
        if (!value.equals(readBack)) {
            throw new IllegalStateException(
                "Secure store verification failed for key '" + key
                    + "': the value read back does not match the value just written, so the encrypted store cannot be trusted.");
        }
    }

    //
    // Removes a key. A missing key is not an error.
    //
    public void delete(String key) {
        backing.remove(key);
    }

    //
    // Returns every stored key.
    //
    public List<String> keys() {
        return new ArrayList<>(backing.keys());
    }

    //
    // The production backing over EncryptedSharedPreferences. Writes are committed synchronously so a
    // value is durable before the plugin/host call resolves (a secret must survive an immediate restart).
    //
    private static final class SharedPreferencesBacking implements Backing {

        //
        // The encrypted preferences the secrets are stored in.
        //
        private final SharedPreferences preferences;

        //
        // Wraps the encrypted preferences.
        //
        SharedPreferencesBacking(SharedPreferences preferences) {
            this.preferences = preferences;
        }

        @Override
        public String getString(String key) {
            return preferences.getString(key, null);
        }

        @Override
        public void putString(String key, String value) {
            preferences.edit().putString(key, value).commit();
        }

        @Override
        public void remove(String key) {
            preferences.edit().remove(key).commit();
        }

        @Override
        public Set<String> keys() {
            Set<String> keys = new java.util.HashSet<>();
            for (Map.Entry<String, ?> entry : preferences.getAll().entrySet()) {
                // The keyset-durability sentinel is bookkeeping, not a stored secret.
                if (KEYSET_SENTINEL_KEY.equals(entry.getKey())) {
                    continue;
                }
                keys.add(entry.getKey());
            }
            return keys;
        }
    }
}
