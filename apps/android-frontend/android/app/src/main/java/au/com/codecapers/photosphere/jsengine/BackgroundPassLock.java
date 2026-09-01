package au.com.codecapers.photosphere.jsengine;

//
// Keeps a background import pass and a background sync pass from running at the same time.
//
// The two loops know nothing about each other and run on threads of their own, and they must not
// overlap. An import pass holds the database write lock for as long as it runs, and it holds a chain
// of engine slots: import-assets holds one for the whole run, and the hash-file and upload-asset
// tasks it queues hold more, all inside EnginePool.POOL_SIZE. A sync started in the middle of one
// would take a slot of its own and then wait for a write lock the import is not going to release for
// a while. That is the exact arrangement that deadlocked the pool once already: everything in it
// waiting on something that could not start, with the feature switched on, the tasks showing as
// running and the counts at zero forever. See docs/mobile-background-tasks.md.
//
// It is a try-and-skip lock rather than one that waits. A loop that cannot take it abandons that pass
// and asks again after its usual gap, so no thread is ever parked on it: a first backup of a whole
// photo library is the better part of an hour, and a sync thread waiting that long is a thread that
// cannot notice the app being switched off.
//
// Nothing here touches Android, so what it does can be unit tested on the JVM.
//
public final class BackgroundPassLock {

    //
    // The name of whatever holds the lock, or null when nothing does. Kept rather than a plain flag
    // so a loop that is skipping its passes can say what it is skipping behind.
    //
    private String holder = null;

    //
    // Takes the lock for the named owner, or reports that something else has it.
    //
    // Returns false rather than waiting, which is the whole point: the caller skips this pass.
    // Re-entrant acquisition is not allowed either, so an owner that failed to release cannot quietly
    // take the lock a second time and hide the leak.
    //
    public synchronized boolean tryAcquire(String owner) {
        if (holder != null) {
            return false;
        }
        holder = owner;
        return true;
    }

    //
    // Gives the lock up.
    //
    // A release by anything other than the current holder is ignored rather than obeyed. Releasing a
    // lock somebody else holds would let two passes run at once, which is the one thing this exists
    // to prevent, and it can only happen through a bug in a caller's finally block.
    //
    public synchronized void release(String owner) {
        if (holder != null && holder.equals(owner)) {
            holder = null;
        }
    }

    //
    // True while a pass is running.
    //
    public synchronized boolean isHeld() {
        return holder != null;
    }

    //
    // The name of whatever holds the lock, or null when nothing does.
    //
    public synchronized String holder() {
        return holder;
    }
}
