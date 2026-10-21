package au.com.codecapers.photosphere.ziggy;

import android.content.Context;
import android.content.SharedPreferences;
import androidx.security.crypto.EncryptedSharedPreferences;
import androidx.security.crypto.MasterKeys;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Set;

// The device keychain the phone's secrets are kept in. They are stored encrypted at rest, so they match what the OS keychain gives a
// desktop instead of sitting in a plain file.
//
// The storage logic is written against a small Backing interface so it is unit-testable on a plain JVM with an in-memory backing.
// Production uses forContext(), which backs it with Jetpack Security's EncryptedSharedPreferences: keys and values are encrypted with a
// master key held in the hardware-backed Android Keystore.
public final class SecureStore {
    // The name of the encrypted shared-preferences file the production backing stores items in.
    private static final String PREFS_FILE_NAME = "photosphere_secure_store";

    // Key of a dummy entry committed synchronously when the store is created, purely to force the Tink keyset to disk (see forContext).
    // Hidden from keys() so it never looks like a stored secret.
    private static final String KEYSET_SENTINEL_KEY = "__photosphere_keyset_sentinel__";

    // The process-wide store over the fixed encrypted-preferences file, built once by forContext() and shared by every caller.
    // EncryptedSharedPreferences is not safe to create concurrently over the same file: two racing create() calls re-initialise the
    // Tink keyset, so a value written under one keyset can no longer be decrypted and reads back empty. Building a single instance once,
    // under the class monitor, removes that race.
    private static SecureStore sharedInstance;

    // How many times forContext() tries to build the store before giving up. The Android Keystore that holds the master key can
    // transiently fail to serve or decrypt the key when several app processes start in quick succession, so a few tries ride over it.
    private static final int CREATE_MAX_ATTEMPTS = 6;

    // The delay between store-creation attempts, in milliseconds.
    private static final long CREATE_RETRY_DELAY_MS = 150;

    // Builds a SecureStore. An interface so createWithRetry() is unit-testable with a fake creator: the real one touches the Android
    // Keystore, which a plain JVM does not have.
    public interface StoreCreator {
        // Creates the store, or throws when the underlying secure hardware or keyset is transiently unavailable.
        SecureStore create() throws Exception;
    }

    // The persistence layer the store reads and writes. Abstracted so unit tests can supply an in-memory implementation.
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

    private final Backing backing;

    public SecureStore(Backing backing) {
        this.backing = backing;
    }

    // Returns the process-wide store backed by EncryptedSharedPreferences, building it once on first use. The application context is
    // used so the singleton never holds a shorter-lived Activity context.
    public static synchronized SecureStore forContext(Context context) throws Exception {
        if (sharedInstance == null) {
            final Context applicationContext = context.getApplicationContext();

            // Built under a bounded retry so a transient Keystore failure does not surface as a lost secret. sharedInstance is
            // assigned only on success, so a total failure leaves it null and the next call tries afresh.
            sharedInstance = createWithRetry(() -> {
                String masterKeyAlias = MasterKeys.getOrCreate(MasterKeys.AES256_GCM_SPEC);

                SharedPreferences preferences = EncryptedSharedPreferences.create(
                    PREFS_FILE_NAME,
                    masterKeyAlias,
                    applicationContext,
                    EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                    EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM);

                // Force the Tink keyset to disk synchronously. EncryptedSharedPreferences generates the keyset on first use and
                // persists it with apply(), which flushes on a background thread, so a process killed straight away (as a test's
                // force-stop does) can lose a newly generated keyset even though the secret itself was committed. The next launch
                // would then generate a fresh keyset and every existing entry would become unreachable, reading back absent with no
                // error. Committing a sentinel persists the whole preferences map, keyset included, before the process can be killed.
                preferences.edit().putString(KEYSET_SENTINEL_KEY, "1").commit();

                return new SecureStore(new SharedPreferencesBacking(preferences));
            }, CREATE_MAX_ATTEMPTS, CREATE_RETRY_DELAY_MS);
        }
        return sharedInstance;
    }

    // Builds a store using the given creator, retrying on failure up to maxAttempts with a fixed backoff between tries. The last
    // failure is rethrown when every attempt fails, so a persistent failure is still loud.
    static SecureStore createWithRetry(StoreCreator creator, int maxAttempts, long backoffMillis) throws Exception {
        Exception lastError = null;
        for (int attempt = 1; attempt <= maxAttempts; attempt++) {
            try {
                return creator.create();
            } catch (Exception error) {
                lastError = error;
                if (attempt < maxAttempts) {
                    try {
                        Thread.sleep(backoffMillis);
                    } catch (InterruptedException interrupted) {
                        // Keep the interrupt and stop retrying: fail with the original error.
                        Thread.currentThread().interrupt();
                        throw error;
                    }
                }
            }
        }
        throw lastError;
    }

    // Returns the stored value for a key, or null when absent.
    public String get(String key) {
        return backing.getString(key);
    }

    // Stores (or overwrites) a value for a key, then reads it straight back. If an entry that was just written cannot be read again
    // (the Tink keyset was regenerated, so the lookup silently misses), it fails here at the write instead of surfacing much later as a
    // secret that did not survive a restart.
    public void set(String key, String value) {
        backing.putString(key, value);
        String readBack = backing.getString(key);
        if (!value.equals(readBack)) {
            throw new IllegalStateException(
                "Secure store verification failed for key '" + key
                    + "': the value read back does not match the value just written, so the encrypted store cannot be trusted.");
        }
    }

    // Removes a key. A missing key is not an error.
    public void delete(String key) {
        backing.remove(key);
    }

    // Returns every stored key.
    public List<String> keys() {
        return new ArrayList<>(backing.keys());
    }

    // The production backing over EncryptedSharedPreferences. Writes are committed synchronously so a value is durable before the
    // request is answered (a secret must survive an immediate restart).
    private static final class SharedPreferencesBacking implements Backing {
        private final SharedPreferences preferences;

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
