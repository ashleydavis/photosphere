package au.com.codecapers.photosphere.jsengine;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

//
// Plain-JVM unit tests for the lock that keeps a background import pass and a background sync pass
// from running at the same time.
//
// What this stops is not a rare race. An import holds the database write lock and a chain of engine
// slots for the length of a run, and a sync started inside that takes a slot of its own and waits for
// a lock it will not get, which is how the engine pool deadlocked once already: silently, with the
// feature switched on and the counts at zero forever.
//
public final class BackgroundPassLockTest {

    @Test
    public void nothingHoldsTheLockToStartWith() {
        BackgroundPassLock lock = new BackgroundPassLock();

        assertFalse(lock.isHeld());
        assertNull(lock.holder());
    }

    @Test
    public void theFirstToAskGetsIt() {
        BackgroundPassLock lock = new BackgroundPassLock();

        assertTrue(lock.tryAcquire(AutoImportDriver.PASS_LOCK_OWNER));
        assertTrue(lock.isHeld());
        assertEquals(AutoImportDriver.PASS_LOCK_OWNER, lock.holder());
    }

    @Test
    public void theSecondToAskIsRefusedRatherThanQueued() {
        // Refused rather than made to wait, so no loop is ever parked on it: a first backup of a
        // whole photo library runs for the better part of an hour.
        BackgroundPassLock lock = new BackgroundPassLock();
        assertTrue(lock.tryAcquire(AutoImportDriver.PASS_LOCK_OWNER));

        assertFalse(lock.tryAcquire(SyncDriver.PASS_LOCK_OWNER));
    }

    @Test
    public void theHolderCannotTakeItTwice() {
        // A second acquisition by the same owner would mean a release somewhere was missed, and
        // allowing it would hide that rather than leaving it to be found.
        BackgroundPassLock lock = new BackgroundPassLock();
        assertTrue(lock.tryAcquire(SyncDriver.PASS_LOCK_OWNER));

        assertFalse(lock.tryAcquire(SyncDriver.PASS_LOCK_OWNER));
    }

    @Test
    public void releasingLetsTheOtherLoopIn() {
        BackgroundPassLock lock = new BackgroundPassLock();
        assertTrue(lock.tryAcquire(AutoImportDriver.PASS_LOCK_OWNER));

        lock.release(AutoImportDriver.PASS_LOCK_OWNER);

        assertFalse(lock.isHeld());
        assertTrue(lock.tryAcquire(SyncDriver.PASS_LOCK_OWNER));
    }

    @Test
    public void aReleaseByAnythingButTheHolderIsIgnored() {
        // Obeying it would let two passes run at once, which is the one thing this exists to
        // prevent, and it can only happen through a bug in a caller's finally block.
        BackgroundPassLock lock = new BackgroundPassLock();
        assertTrue(lock.tryAcquire(AutoImportDriver.PASS_LOCK_OWNER));

        lock.release(SyncDriver.PASS_LOCK_OWNER);

        assertTrue(lock.isHeld());
        assertEquals(AutoImportDriver.PASS_LOCK_OWNER, lock.holder());
        assertFalse(lock.tryAcquire(SyncDriver.PASS_LOCK_OWNER));
    }

    @Test
    public void releasingWhenNothingHoldsItDoesNothing() {
        BackgroundPassLock lock = new BackgroundPassLock();

        lock.release(SyncDriver.PASS_LOCK_OWNER);

        assertFalse(lock.isHeld());
    }

    @Test
    public void onlyOneOfManyThreadsAskingAtOnceGetsIt() throws Exception {
        // The two loops run on threads of their own and ask without any coordination between them.
        final BackgroundPassLock lock = new BackgroundPassLock();
        final int askerCount = 8;
        final java.util.concurrent.atomic.AtomicInteger acquired = new java.util.concurrent.atomic.AtomicInteger(0);
        final java.util.concurrent.CountDownLatch startTogether = new java.util.concurrent.CountDownLatch(1);
        Thread[] askers = new Thread[askerCount];

        for (int askerIndex = 0; askerIndex < askerCount; askerIndex++) {
            askers[askerIndex] = new Thread(new Runnable() {
                @Override
                public void run() {
                    try {
                        startTogether.await(5, java.util.concurrent.TimeUnit.SECONDS);
                    }
                    catch (InterruptedException interrupted) {
                        Thread.currentThread().interrupt();
                        return;
                    }
                    if (lock.tryAcquire("asker")) {
                        acquired.incrementAndGet();
                    }
                }
            });
            askers[askerIndex].start();
        }

        startTogether.countDown();
        for (Thread asker : askers) {
            asker.join(5000);
        }

        assertEquals("exactly one asker may hold the lock", 1, acquired.get());
    }
}
