package au.com.codecapers.photosphere.jsengine;

import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicBoolean;

//
// Per-task cancellation flags, designed so host.isCancelled(taskId) can be polled from
// inside a running task WITHOUT taking the dispatcher lock. Each task gets an
// AtomicBoolean; reads and writes are lock-free and memory-visible across threads. The
// dispatcher mutates flags (when cancelTasks records a source) under its own lock, but a
// running engine thread only ever reads them here, so there is no lock-ordering hazard
// with the engine event loop.
//
public final class CancellationState {

    //
    // Map of taskId -> its atomic cancelled flag. ConcurrentHashMap so register/unregister
    // from the dispatcher thread and isCancelled reads from engine threads are safe without
    // an external lock.
    //
    private final ConcurrentHashMap<String, AtomicBoolean> flagsByTaskId = new ConcurrentHashMap<>();

    //
    // Registers a task with an initial cancelled state. Called when the task is enqueued.
    //
    public void register(String taskId, boolean cancelled) {
        flagsByTaskId.put(taskId, new AtomicBoolean(cancelled));
    }

    //
    // Marks a task cancelled. Safe to call even if the task was never registered or already
    // unregistered (a no-op in that case).
    //
    public void setCancelled(String taskId) {
        AtomicBoolean flag = flagsByTaskId.get(taskId);
        if (flag != null) {
            flag.set(true);
        }
    }

    //
    // Returns whether the task is cancelled. This is the lock-free read host.isCancelled
    // performs mid-task. An unknown task id reads as not cancelled.
    //
    public boolean isCancelled(String taskId) {
        AtomicBoolean flag = flagsByTaskId.get(taskId);
        return flag != null && flag.get();
    }

    //
    // Removes a task's flag once it is no longer needed (completed or dropped).
    //
    public void unregister(String taskId) {
        flagsByTaskId.remove(taskId);
    }

    //
    // Clears every flag. Used during pool shutdown.
    //
    public void clear() {
        flagsByTaskId.clear();
    }
}
