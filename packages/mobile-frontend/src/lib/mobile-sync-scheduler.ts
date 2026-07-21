//
// The mobile background-sync scheduler.
//
// It mirrors desktop's scheduler (apps/desktop/src/main.ts): a debounced sync after an edit, a periodic
// sync, and a gate that never enqueues a sync unless the shared SyncContext permits it, a database is
// open, and no sync is already running. It is a pure module (timers + gate + an injected addTask
// callback) so it is unit-testable with fake timers, following the mobile-config-store precedent rather
// than living in the shared user-interface package or the React provider.
//
// The provider owns one instance and drives it from the platform-context methods (notifyDatabaseEdited,
// setSyncAllowed, database-opened) and from the worker's sync-started/sync-completed task messages.
//

//
// The debounce window after an edit before a sync is enqueued (matches desktop's 10s).
//
export const SYNC_DEBOUNCE_MS = 10_000;

//
// The periodic sync interval (matches desktop's 5 minutes).
//
export const SYNC_PERIOD_MS = 5 * 60 * 1_000;

//
// The task type enqueued for a sync (registered by the mobile worker entry).
//
export const SYNC_TASK_TYPE = "sync-database";

//
// The input payload for a sync-database task. Only the database path is needed; the worker resolves the
// origin from the database config itself.
//
export interface ISyncTaskData {
    // The local path of the database to sync.
    databasePath: string;
}

//
// Enqueues a task on the worker queue. Mirrors the desktop `workerPool.addTask(type, data, source)` and
// the mobile `EmbeddedJsQueueBackend.addTask` surface; injected so the scheduler stays a pure module.
//
export type AddTaskCallback = (type: string, data: ISyncTaskData, source: string) => void;

//
// Schedules background database syncs on mobile.
//
export class MobileSyncScheduler {
    //
    // Whether the shared sync gate currently permits automatic syncs.
    //
    private syncAllowed = false;

    //
    // The path of the open database, or undefined when none is open.
    //
    private currentDatabasePath: string | undefined = undefined;

    //
    // Whether a sync task is currently running (set when enqueued, cleared on completion).
    //
    private isSyncRunning = false;

    //
    // The pending debounce timer handle, or undefined when none is scheduled.
    //
    private debounceTimer: NodeJS.Timeout | undefined = undefined;

    //
    // The periodic timer handle, or undefined when the periodic sync is not started.
    //
    private periodicTimer: NodeJS.Timeout | undefined = undefined;

    //
    // The injected enqueue callback.
    //
    private readonly addTask: AddTaskCallback;

    //
    // Builds a scheduler that enqueues syncs through the given callback.
    //
    constructor(addTask: AddTaskCallback) {
        this.addTask = addTask;
    }

    //
    // Records the open database path (or undefined when the database closes). A newly opened database
    // becomes the sync target; closing clears it so no sync is enqueued for a closed database.
    //
    setDatabasePath(databasePath: string | undefined): void {
        this.currentDatabasePath = databasePath;
    }

    //
    // Pushes the shared sync gate's decision. When sync becomes allowed, schedules a catch-up sync
    // (matching desktop's set-sync-allowed behaviour); when disallowed, cancels any pending debounce so
    // no automatic sync fires.
    //
    setSyncAllowed(allowed: boolean): void {
        this.syncAllowed = allowed;
        if (allowed) {
            this.scheduleSync();
        }
        else if (this.debounceTimer !== undefined) {
            clearTimeout(this.debounceTimer);
            this.debounceTimer = undefined;
        }
    }

    //
    // Notifies the scheduler that the database was edited, scheduling a debounced sync.
    //
    notifyDatabaseEdited(): void {
        this.scheduleSync();
    }

    //
    // Starts the periodic sync timer (idempotent).
    //
    start(): void {
        if (this.periodicTimer !== undefined) {
            return;
        }
        this.periodicTimer = setInterval(() => {
            this.enqueueSyncTask();
        }, SYNC_PERIOD_MS);
    }

    //
    // Stops the scheduler: clears the periodic and debounce timers.
    //
    stop(): void {
        if (this.periodicTimer !== undefined) {
            clearInterval(this.periodicTimer);
            this.periodicTimer = undefined;
        }
        if (this.debounceTimer !== undefined) {
            clearTimeout(this.debounceTimer);
            this.debounceTimer = undefined;
        }
    }

    //
    // Marks the running sync as settled (called on a sync-completed / sync-failed task message), so the
    // next scheduled or periodic sync can be enqueued.
    //
    onSyncSettled(): void {
        this.isSyncRunning = false;
    }

    //
    // Schedules a debounced sync: resets any pending timer so rapid edits coalesce into one enqueue.
    //
    private scheduleSync(): void {
        if (this.debounceTimer !== undefined) {
            clearTimeout(this.debounceTimer);
        }
        this.debounceTimer = setTimeout(() => {
            this.debounceTimer = undefined;
            this.enqueueSyncTask();
        }, SYNC_DEBOUNCE_MS);
    }

    //
    // Enqueues a sync task if the gate permits it: sync allowed, a database open, and no sync already
    // running. Mirrors desktop's enqueueSyncTask gate exactly.
    //
    private enqueueSyncTask(): void {
        if (!this.syncAllowed || this.currentDatabasePath === undefined || this.isSyncRunning) {
            return;
        }
        this.isSyncRunning = true;
        this.addTask(SYNC_TASK_TYPE, { databasePath: this.currentDatabasePath }, this.currentDatabasePath);
    }
}
