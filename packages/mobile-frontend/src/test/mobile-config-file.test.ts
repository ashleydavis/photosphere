import { DEFAULT_SYNC_PAUSE_MS, DEFAULT_SYNC_SETTINGS, INITIAL_SYNC_SETTINGS } from "api/src/lib/sync-settings";
import { planSyncSeed, planSyncDatabase, type IMobileSyncSettings } from "../lib/mobile-config-file";

//
// Tests for the two decisions the phone makes about the syncing section of config.yaml that no other
// platform makes: what to write into a fresh installation, and what to write when a database is
// opened.
//
// Reading and writing the file itself goes through the embedded worker and is covered by the Android
// suite. What is here is the deciding, because getting it wrong is a phone that quietly stops pushing
// photos, one that pushes them over cellular after being told not to, or one that has a user's choice
// overwritten every time the app starts.
//
// Every other setting is read and written the ordinary way, the same as on the desktop, so there is
// nothing mobile-specific left to test about it.
//

//
// The syncing section as it reads before anybody has written it.
//
function neverWritten(): IMobileSyncSettings {
    return {
        settings: { ...DEFAULT_SYNC_SETTINGS },
        databasePath: undefined,
        pauseBetweenRunsMs: DEFAULT_SYNC_PAUSE_MS,
        written: false,
    };
}

//
// The syncing section as it reads once it holds the given settings.
//
function written(enabled: boolean, onlyOnWifi: boolean, databasePath: string | undefined, pauseBetweenRunsMs: number = DEFAULT_SYNC_PAUSE_MS): IMobileSyncSettings {
    return {
        settings: {
            enabled,
            onlyOnWifi,
        },
        databasePath,
        pauseBetweenRunsMs,
        written: true,
    };
}

describe("seeding the syncing settings", () => {

    test("writes the settings a fresh installation starts from", () => {
        // A section nobody has written reads as syncing off, which is the safe answer for the
        // background loop and the wrong one for a new user whose toggles show syncing on.
        expect(planSyncSeed(neverWritten())).toEqual({
            settings: { ...INITIAL_SYNC_SETTINGS },
            databasePath: undefined,
            pauseBetweenRunsMs: DEFAULT_SYNC_PAUSE_MS,
        });
    });

    test("leaves settings that have been written exactly as they are", () => {
        // Otherwise syncing would go back on for somebody who switched it off, every time the app
        // started.
        expect(planSyncSeed(written(false, false, "a-database"))).toBeUndefined();
    });

    test("keeps the database and the pacing already recorded", () => {
        // Automatic import can have recorded a database before syncing was ever seeded, and seeding
        // must not lose it.
        expect(planSyncSeed({ ...neverWritten(), databasePath: "recorded-earlier", pauseBetweenRunsMs: 90000 }))
            .toEqual({
                settings: { ...INITIAL_SYNC_SETTINGS },
                databasePath: "recorded-earlier",
                pauseBetweenRunsMs: 90000,
            });
    });

    test("a pacing of zero falls back to the default rather than being written as zero", () => {
        // Zero would be a loop with no gap between passes.
        expect(planSyncSeed({ ...neverWritten(), pauseBetweenRunsMs: 0 })?.pauseBetweenRunsMs)
            .toBe(DEFAULT_SYNC_PAUSE_MS);
    });
});

describe("recording the database the background sync pushes", () => {

    test("records a database when none has been recorded", () => {
        expect(planSyncDatabase(neverWritten(), "opened-database")).toEqual({
            settings: { ...INITIAL_SYNC_SETTINGS },
            databasePath: "opened-database",
            pauseBetweenRunsMs: DEFAULT_SYNC_PAUSE_MS,
        });
    });

    test("records a database that differs from the one already recorded", () => {
        expect(planSyncDatabase(written(true, false, "old-database"), "new-database")).toEqual({
            settings: {
                enabled: true,
                onlyOnWifi: false,
            },
            databasePath: "new-database",
            pauseBetweenRunsMs: DEFAULT_SYNC_PAUSE_MS,
        });
    });

    test("leaves the file alone when the same database is opened again", () => {
        // A database is opened on every launch and on every switch between databases, so rewriting
        // the file to say what it already says would be a write per launch for nothing.
        expect(planSyncDatabase(written(true, true, "same-database"), "same-database")).toBeUndefined();
    });

    test("keeps the settings the user chose", () => {
        // Recording a database must never switch syncing on for somebody who switched it off.
        expect(planSyncDatabase(written(false, false, undefined), "opened-database")?.settings)
            .toEqual({
                enabled: false,
                onlyOnWifi: false,
            });
    });

    test("starts from the fresh-install settings when nobody has chosen any yet", () => {
        // Opening a database can happen before the seeding has run. Writing the reader's defaults
        // here would record syncing as switched off without anybody having switched it off.
        expect(planSyncDatabase(neverWritten(), "opened-database")?.settings)
            .toEqual({ ...INITIAL_SYNC_SETTINGS });
    });

    test("keeps the pacing already recorded", () => {
        expect(planSyncDatabase(written(true, true, "old-database", 90000), "new-database")?.pauseBetweenRunsMs)
            .toBe(90000);
    });
});
