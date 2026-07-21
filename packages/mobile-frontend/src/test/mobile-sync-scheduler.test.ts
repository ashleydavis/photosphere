import { MobileSyncScheduler, SYNC_DEBOUNCE_MS, SYNC_PERIOD_MS, SYNC_TASK_TYPE, type ISyncTaskData } from "../lib/mobile-sync-scheduler";

//
// A recorded enqueue call.
//
interface IEnqueueCall {
    // The task type enqueued.
    type: string;

    // The task data enqueued.
    data: ISyncTaskData;

    // The source tag.
    source: string;
}

describe("MobileSyncScheduler", () => {

    let enqueued: IEnqueueCall[];
    let scheduler: MobileSyncScheduler;

    beforeEach(() => {
        jest.useFakeTimers();
        enqueued = [];
        scheduler = new MobileSyncScheduler((type, data, source) => {
            enqueued.push({ type, data, source });
        });
    });

    afterEach(() => {
        scheduler.stop();
        jest.useRealTimers();
    });

    test("does not enqueue when sync is not allowed", () => {
        scheduler.setDatabasePath("/dbs/photos");
        scheduler.notifyDatabaseEdited();
        jest.advanceTimersByTime(SYNC_DEBOUNCE_MS);
        expect(enqueued).toHaveLength(0);
    });

    test("does not enqueue when no database is open", () => {
        scheduler.setSyncAllowed(true);
        jest.advanceTimersByTime(SYNC_DEBOUNCE_MS);
        expect(enqueued).toHaveLength(0);
    });

    test("debounce coalesces rapid edits into a single enqueue", () => {
        scheduler.setDatabasePath("/dbs/photos");
        scheduler.setSyncAllowed(true);
        jest.advanceTimersByTime(SYNC_DEBOUNCE_MS);
        // The set-allowed catch-up fired once; settle it and clear before testing the edit debounce.
        scheduler.onSyncSettled();
        enqueued = [];

        scheduler.notifyDatabaseEdited();
        scheduler.notifyDatabaseEdited();
        scheduler.notifyDatabaseEdited();
        jest.advanceTimersByTime(SYNC_DEBOUNCE_MS);

        expect(enqueued).toHaveLength(1);
        expect(enqueued[0].type).toBe(SYNC_TASK_TYPE);
        expect(enqueued[0].data).toEqual({ databasePath: "/dbs/photos" });
        expect(enqueued[0].source).toBe("/dbs/photos");
    });

    test("the gate blocks a second sync while one is already running", () => {
        scheduler.setDatabasePath("/dbs/photos");
        scheduler.setSyncAllowed(true);
        jest.advanceTimersByTime(SYNC_DEBOUNCE_MS);
        expect(enqueued).toHaveLength(1);

        // A sync is now running; another edit must not enqueue until it settles.
        scheduler.notifyDatabaseEdited();
        jest.advanceTimersByTime(SYNC_DEBOUNCE_MS);
        expect(enqueued).toHaveLength(1);

        scheduler.onSyncSettled();
        scheduler.notifyDatabaseEdited();
        jest.advanceTimersByTime(SYNC_DEBOUNCE_MS);
        expect(enqueued).toHaveLength(2);
    });

    test("the periodic timer enqueues a sync", () => {
        scheduler.setDatabasePath("/dbs/photos");
        scheduler.setSyncAllowed(true);
        jest.advanceTimersByTime(SYNC_DEBOUNCE_MS);
        scheduler.onSyncSettled();
        enqueued = [];

        scheduler.start();
        jest.advanceTimersByTime(SYNC_PERIOD_MS);
        expect(enqueued).toHaveLength(1);
        expect(enqueued[0].data).toEqual({ databasePath: "/dbs/photos" });
    });

    test("setSyncAllowed(true) triggers a catch-up sync", () => {
        scheduler.setDatabasePath("/dbs/photos");
        scheduler.setSyncAllowed(true);
        jest.advanceTimersByTime(SYNC_DEBOUNCE_MS);
        expect(enqueued).toHaveLength(1);
    });

    test("setSyncAllowed(false) cancels a pending debounced sync", () => {
        scheduler.setDatabasePath("/dbs/photos");
        scheduler.setSyncAllowed(true);
        jest.advanceTimersByTime(SYNC_DEBOUNCE_MS);
        scheduler.onSyncSettled();
        enqueued = [];

        scheduler.notifyDatabaseEdited();
        scheduler.setSyncAllowed(false);
        jest.advanceTimersByTime(SYNC_DEBOUNCE_MS);
        expect(enqueued).toHaveLength(0);
    });
});
