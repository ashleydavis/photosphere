package au.com.codecapers.photosphere.ziggy;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertSame;
import static org.junit.Assert.assertTrue;
import static org.junit.Assert.fail;

import java.util.HashMap;
import java.util.HashSet;
import java.util.Map;
import java.util.Set;
import org.junit.Test;

// Plain-JVM tests for the keychain's storage logic over an in-memory backing, and for the retry that rides over a Keystore that is
// briefly unavailable.
public final class SecureStoreTest {
    // A backing that keeps items in a map. When forgetful, it accepts a write and then reads nothing back, as a store whose keyset
    // was regenerated does.
    private static final class MemoryBacking implements SecureStore.Backing {
        private final Map<String, String> items = new HashMap<String, String>();
        private final boolean forgetful;

        MemoryBacking(boolean forgetful) {
            this.forgetful = forgetful;
        }

        @Override
        public String getString(String key) {
            return forgetful ? null : items.get(key);
        }

        @Override
        public void putString(String key, String value) {
            items.put(key, value);
        }

        @Override
        public void remove(String key) {
            items.remove(key);
        }

        @Override
        public Set<String> keys() {
            return new HashSet<String>(items.keySet());
        }
    }

    @Test
    public void aValueWrittenCanBeReadBackAndAMissingKeyIsNull() {
        SecureStore store = new SecureStore(new MemoryBacking(false));
        store.set("photosphere.secret.one", "s3cret");
        assertEquals("s3cret", store.get("photosphere.secret.one"));
        assertNull(store.get("photosphere.secret.two"));
    }

    @Test
    public void deletingAKeyRemovesItAndDeletingAMissingKeyIsNotAnError() {
        SecureStore store = new SecureStore(new MemoryBacking(false));
        store.set("a", "1");
        store.delete("a");
        store.delete("a");
        assertNull(store.get("a"));
    }

    @Test
    public void keysListsEveryStoredKey() {
        SecureStore store = new SecureStore(new MemoryBacking(false));
        store.set("a", "1");
        store.set("b", "2");
        assertEquals(new HashSet<String>(java.util.Arrays.asList("a", "b")), new HashSet<String>(store.keys()));
    }

    @Test
    public void aWriteThatCannotBeReadBackFailsAtTheWrite() {
        SecureStore store = new SecureStore(new MemoryBacking(true));
        try {
            store.set("a", "1");
            fail("The write should have been refused.");
        } catch (IllegalStateException expected) {
            assertTrue(expected.getMessage().contains("verification failed"));
        }
    }

    @Test
    public void creationRetriesAndGivesTheStoreOnceTheKeystoreAnswers() throws Exception {
        final SecureStore store = new SecureStore(new MemoryBacking(false));
        final int[] attempts = new int[] { 0 };
        SecureStore made = SecureStore.createWithRetry(new SecureStore.StoreCreator() {
            @Override
            public SecureStore create() throws Exception {
                attempts[0]++;
                if (attempts[0] < 3) {
                    throw new Exception("Keystore busy");
                }
                return store;
            }
        }, 6, 1);
        assertSame(store, made);
        assertEquals(3, attempts[0]);
    }

    @Test
    public void creationThatNeverWorksFailsWithTheLastError() {
        try {
            SecureStore.createWithRetry(new SecureStore.StoreCreator() {
                @Override
                public SecureStore create() throws Exception {
                    throw new Exception("Keystore gone");
                }
            }, 3, 1);
            fail("Creation should have failed.");
        } catch (Exception expected) {
            assertEquals("Keystore gone", expected.getMessage());
        }
    }
}
