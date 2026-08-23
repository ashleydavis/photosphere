import { DEFAULT_SYNC_WATCH_INTERVAL_SECONDS, parseWatchInterval, runSyncWatch } from "../lib/sync-watch";

describe("parseWatchInterval", () => {

    test("uses the default when none was asked for", () => {
        expect(parseWatchInterval(undefined)).toBe(DEFAULT_SYNC_WATCH_INTERVAL_SECONDS);
    });

    test("takes the number of seconds it was given", () => {
        expect(parseWatchInterval("120")).toBe(120);
    });

    test("refuses an interval that is not a number", () => {
        // Rather than quietly falling back to the default: a watch that syncs every thirty seconds
        // when it was told every hour is exactly the kind of thing nobody notices.
        expect(() => parseWatchInterval("hourly")).toThrow(/positive number of seconds/);
    });

    test("refuses an interval of zero or less", () => {
        expect(() => parseWatchInterval("0")).toThrow(/positive number of seconds/);
        expect(() => parseWatchInterval("-5")).toThrow(/positive number of seconds/);
    });
});

describe("runSyncWatch", () => {

    test("keeps syncing until it is stopped", async () => {
        let syncs = 0;

        await runSyncWatch({
            intervalSeconds: 0.001,
            isStopped: () => syncs >= 3,
            syncOnce: async () => {
                syncs += 1;
                return { synced: true } as any;
            },
        });

        expect(syncs).toBe(3);
    });

    test("a sync that failed does not stop the watch", async () => {
        // A network that is down now may be up in thirty seconds. Stopping would mean nothing syncs
        // again until someone notices.
        let syncs = 0;
        let succeeded = 0;

        await runSyncWatch({
            intervalSeconds: 0.001,
            isStopped: () => syncs >= 3,
            syncOnce: async () => {
                syncs += 1;
                if (syncs === 1) {
                    throw new Error("the network is down");
                }
                succeeded += 1;
                return { synced: true } as any;
            },
        });

        expect(syncs).toBe(3);
        expect(succeeded).toBe(2);
    });

    test("does not sync at all when it is stopped before it starts", async () => {
        let syncs = 0;

        await runSyncWatch({
            intervalSeconds: 0.001,
            isStopped: () => true,
            syncOnce: async () => {
                syncs += 1;
                return { synced: true } as any;
            },
        });

        expect(syncs).toBe(0);
    });
});
