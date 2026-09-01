import Foundation

//
// Keeps a background import pass and a background sync pass from running at the same time.
//
// The counterpart of BackgroundPassLock.java, deliberately identical. An import pass holds the
// database write lock for as long as it runs, and it holds a chain of engine slots: import-assets
// holds one for the whole run, and the hash-file and upload-asset tasks it queues hold more, all
// inside EnginePool.poolSize. A sync started in the middle of one would take a slot of its own and
// then wait for a write lock the import is not going to release for a while. That is the exact
// arrangement that deadlocked the pool once already: everything in it waiting on something that
// could not start, with the feature switched on and the counts at zero forever. See
// docs/mobile-background-tasks.md.
//
// It is a try-and-skip lock rather than one that waits. A loop that cannot take it abandons that pass
// and asks again after its usual gap, so no thread is ever parked on it: a first backup of a whole
// photo library is the better part of an hour, and a sync thread waiting that long is a thread that
// cannot notice the app being switched off.
//
final class BackgroundPassLock {

    //
    // Guards the holder below, which is read and written from both loops' threads.
    //
    private let stateLock = NSLock()

    //
    // The name of whatever holds the lock, or nil when nothing does. Kept rather than a plain flag so
    // a loop that is skipping its passes can say what it is skipping behind.
    //
    private var holderName: String?

    //
    // Takes the lock for the named owner, or reports that something else has it.
    //
    // Returns false rather than waiting, which is the whole point: the caller skips this pass.
    // Re-entrant acquisition is not allowed either, so an owner that failed to release cannot quietly
    // take the lock a second time and hide the leak.
    //
    func tryAcquire(_ owner: String) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        if holderName != nil {
            return false
        }
        holderName = owner
        return true
    }

    //
    // Gives the lock up.
    //
    // A release by anything other than the current holder is ignored rather than obeyed. Releasing a
    // lock somebody else holds would let two passes run at once, which is the one thing this exists
    // to prevent, and it can only happen through a bug in a caller's defer block.
    //
    func release(_ owner: String) {
        stateLock.lock()
        defer { stateLock.unlock() }
        if holderName == owner {
            holderName = nil
        }
    }

    //
    // True while a pass is running.
    //
    var isHeld: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return holderName != nil
    }

    //
    // The name of whatever holds the lock, or nil when nothing does.
    //
    var holder: String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return holderName
    }
}
