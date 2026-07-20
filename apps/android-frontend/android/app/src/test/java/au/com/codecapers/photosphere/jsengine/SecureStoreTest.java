package au.com.codecapers.photosphere.jsengine;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;

//
// Plain-JVM unit tests for the device keychain. The EncryptedSharedPreferences/Keystore integration
// lives only in SecureStore.forContext (not exercised here, no device); the storage logic runs against
// an in-memory Backing so round-trip, delete, missing-key-is-absent, and enumeration are covered without
// an Android runtime, matching the CryptoHost convention. The iOS Keychain accessibility attribute
// (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly) is asserted by the iOS XCTest suite, not here.
//
public final class SecureStoreTest {

    //
    // A simple in-memory Backing standing in for EncryptedSharedPreferences.
    //
    private static final class InMemoryBacking implements SecureStore.Backing {

        //
        // The in-memory contents.
        //
        private final Map<String, String> map = new HashMap<>();

        @Override
        public String getString(String key) {
            return map.get(key);
        }

        @Override
        public void putString(String key, String value) {
            map.put(key, value);
        }

        @Override
        public void remove(String key) {
            map.remove(key);
        }

        @Override
        public Set<String> keys() {
            return map.keySet();
        }
    }

    //
    // A value written under a key reads back unchanged.
    //
    @Test
    public void setThenGetRoundTrips() {
        SecureStore store = new SecureStore(new InMemoryBacking());
        store.set("photosphere.secret.my-api-key", "the-secret-value");
        assertEquals("the-secret-value", store.get("photosphere.secret.my-api-key"));
    }

    //
    // Each secret occupies its own store item, so removing one leaves the others untouched. This is the
    // property that makes a per-secret store different from the single-blob store it replaced.
    //
    @Test
    public void secretsAreIndependentItems() {
        SecureStore store = new SecureStore(new InMemoryBacking());
        store.set("photosphere.secret.first", "value-one");
        store.set("photosphere.secret.second", "value-two");

        store.delete("photosphere.secret.first");

        assertNull(store.get("photosphere.secret.first"));
        assertEquals("value-two", store.get("photosphere.secret.second"));
    }

    //
    // Overwriting a key replaces the value.
    //
    @Test
    public void setOverwritesExistingValue() {
        SecureStore store = new SecureStore(new InMemoryBacking());
        store.set("k", "one");
        store.set("k", "two");
        assertEquals("two", store.get("k"));
    }

    //
    // A missing key reads as absent (null), not an error.
    //
    @Test
    public void missingKeyIsAbsent() {
        SecureStore store = new SecureStore(new InMemoryBacking());
        assertNull(store.get("never-written"));
    }

    //
    // Deleting a key removes it; a subsequent read is absent. Deleting a missing key is not an error.
    //
    @Test
    public void deleteRemovesKey() {
        SecureStore store = new SecureStore(new InMemoryBacking());
        store.set("k", "v");
        store.delete("k");
        assertNull(store.get("k"));
        // Deleting again does not throw.
        store.delete("k");
        assertNull(store.get("k"));
    }

    //
    // keys() enumerates every stored key.
    //
    @Test
    public void keysEnumeratesStoredKeys() {
        SecureStore store = new SecureStore(new InMemoryBacking());
        store.set("a", "1");
        store.set("b", "2");
        List<String> keys = store.keys();
        assertEquals(2, keys.size());
        assertTrue(keys.contains("a"));
        assertTrue(keys.contains("b"));
    }

    //
    // createWithRetry returns the store on the first attempt when the creator succeeds immediately (the
    // no-load case), without sleeping.
    //
    @Test
    public void createWithRetrySucceedsFirstAttempt() throws Exception {
        int[] attempts = { 0 };
        SecureStore expected = new SecureStore(new InMemoryBacking());
        SecureStore actual = SecureStore.createWithRetry(() -> {
            attempts[0]++;
            return expected;
        }, 6, 0);
        assertEquals(1, attempts[0]);
        assertTrue(expected == actual);
    }

    //
    // createWithRetry rides over a transient failure: a creator that throws for the first few attempts
    // and then succeeds returns the store (this is the AndroidKeyStore-under-load case the retry fixes).
    //
    @Test
    public void createWithRetryRecoversAfterTransientFailures() throws Exception {
        int[] attempts = { 0 };
        SecureStore expected = new SecureStore(new InMemoryBacking());
        SecureStore actual = SecureStore.createWithRetry(() -> {
            attempts[0]++;
            if (attempts[0] < 3) {
                throw new Exception("transient keystore failure");
            }
            return expected;
        }, 6, 0);
        assertEquals(3, attempts[0]);
        assertTrue(expected == actual);
    }

    //
    // createWithRetry rethrows the last failure (loudly) when every attempt fails, rather than silently
    // returning a null/empty store that would look like a lost secret.
    //
    @Test
    public void createWithRetryRethrowsAfterExhaustingAttempts() {
        int[] attempts = { 0 };
        Exception thrown = null;
        try {
            SecureStore.createWithRetry(() -> {
                attempts[0]++;
                throw new Exception("persistent failure " + attempts[0]);
            }, 4, 0);
        }
        catch (Exception error) {
            thrown = error;
        }
        assertEquals(4, attempts[0]);
        assertEquals("persistent failure 4", thrown.getMessage());
    }

    //
    // The host-function facade delegates to the store set for tests: round-trip and delete through
    // SecureStoreHost.secureStore* mirror the WebView plugin path.
    //
    @Test
    public void hostFunctionsDelegateToStore() {
        SecureStore store = new SecureStore(new InMemoryBacking());
        SecureStoreHost.setStoreForTest(store);

        SecureStoreHost.secureStoreSet("photosphere.secret.my-api-key", "the-secret-value");
        assertEquals("the-secret-value", SecureStoreHost.secureStoreGet("photosphere.secret.my-api-key"));

        SecureStoreHost.secureStoreDelete("photosphere.secret.my-api-key");
        assertNull(SecureStoreHost.secureStoreGet("photosphere.secret.my-api-key"));
    }

    //
    // A backing that accepts writes but never returns them, standing in for an encrypted store whose
    // Tink keyset was regenerated: existing entries become unreachable and, because key names are
    // encrypted deterministically, the lookup misses silently rather than raising.
    //
    private static final class WriteOnlyBacking implements SecureStore.Backing {

        @Override
        public String getString(String key) {
            return null;
        }

        @Override
        public void putString(String key, String value) {
            // Accepted and discarded, exactly as a write under a stale keyset appears to behave.
        }

        @Override
        public void remove(String key) {
        }

        @Override
        public Set<String> keys() {
            return new HashMap<String, String>().keySet();
        }
    }

    //
    // A write that cannot be read back fails at the write, so a broken encrypted store is reported when
    // the secret is saved rather than showing up later as a secret that did not survive a restart.
    //
    @Test
    public void setFailsWhenTheValueDoesNotReadBack() {
        SecureStore store = new SecureStore(new WriteOnlyBacking());

        IllegalStateException thrown = null;
        try {
            store.set("photosphere.secret.my-api-key", "the-secret-value");
        }
        catch (IllegalStateException error) {
            thrown = error;
        }

        assertTrue(thrown != null);
        assertTrue(thrown.getMessage().contains("verification failed"));
    }
}
