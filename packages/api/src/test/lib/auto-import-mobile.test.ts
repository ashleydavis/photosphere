import { DEFAULT_AUTO_IMPORT_SETTINGS, IAutoImportSettings } from "../../lib/auto-import-settings";
import {
    DEFAULT_AUTO_IMPORT_PAUSE_MS,
    DEFAULT_DATABASE_FOLDER_NAME,
    WHOLE_LIBRARY_SOURCES,
    planMobileAutoImport,
    resolveAutoImportPauseMs,
} from "../../lib/auto-import-mobile";

//
// Settings with automatic import switched on and whatever else the test needs.
//
function settingsWith(overrides: Partial<IAutoImportSettings>): IAutoImportSettings {
    return { ...DEFAULT_AUTO_IMPORT_SETTINGS, enabled: true, ...overrides };
}

describe("planMobileAutoImport", () => {

    test("does not run when nothing has been stored", () => {
        expect(planMobileAutoImport(undefined, undefined).shouldRun).toBe(false);
    });

    test("does not run when automatic import is switched off", () => {
        expect(planMobileAutoImport(settingsWith({ enabled: false }), undefined).shouldRun).toBe(false);
    });

    test("runs when automatic import is switched on", () => {
        expect(planMobileAutoImport(settingsWith({}), undefined).shouldRun).toBe(true);
    });

    test("watches the whole library when no albums are chosen", () => {
        const plan = planMobileAutoImport(settingsWith({}), undefined);

        expect(plan.settings.sources).toEqual(WHOLE_LIBRARY_SOURCES);
    });

    test("watches the chosen albums when there are some", () => {
        const plan = planMobileAutoImport(
            settingsWith({ sources: [{ type: "device-album", albumId: "camera" }] }),
            undefined);

        expect(plan.settings.sources).toEqual([{ type: "device-album", albumId: "camera" }]);
    });

    test("drops a malformed stored source rather than failing to start", () => {
        const stored = {
            ...DEFAULT_AUTO_IMPORT_SETTINGS,
            enabled: true,
            sources: [{ type: "device-album" }, { type: "device-album", albumId: "camera" }],
        } as any;

        expect(planMobileAutoImport(stored, undefined).settings.sources)
            .toEqual([{ type: "device-album", albumId: "camera" }]);
    });

    test("chooses the default database location when none has been chosen", () => {
        const plan = planMobileAutoImport(settingsWith({}), undefined);

        expect(plan.isNewDefault).toBe(true);
        expect(plan.databasePath).toBe(DEFAULT_DATABASE_FOLDER_NAME);
    });

    test("uses the chosen default database when there is one", () => {
        const plan = planMobileAutoImport(settingsWith({}), "my-photos");

        expect(plan.isNewDefault).toBe(false);
        expect(plan.databasePath).toBe("my-photos");
    });

    test("an empty stored default counts as none chosen", () => {
        const plan = planMobileAutoImport(settingsWith({}), "");

        expect(plan.isNewDefault).toBe(true);
        expect(plan.databasePath).toBe(DEFAULT_DATABASE_FOLDER_NAME);
    });

    test("the pacing is the shared default, not something the settings invented", () => {
        const plan = planMobileAutoImport(settingsWith({}), undefined);

        expect(plan.settings.backfillItemsPerMinute).toBe(60);
    });

    test("the default database has the same name as the desktop one", () => {
        // A user with both should see the same database name, and a support answer about one should
        // apply to the other.
        expect(DEFAULT_DATABASE_FOLDER_NAME).toBe("photosphere-default");
    });
});

describe("the gap between background import passes", () => {

    test("a gap the file asked for is used as it is", () => {
        expect(resolveAutoImportPauseMs(1500)).toBe(1500);
    });

    test("no gap at all means the default", () => {
        expect(resolveAutoImportPauseMs(undefined)).toBe(DEFAULT_AUTO_IMPORT_PAUSE_MS);
    });

    test("a gap of zero falls back to the default rather than spinning", () => {
        // Zero is a loop that starts a fresh pass the instant the last one ends, which on a phone is
        // a flat battery rather than a fast backup.
        expect(resolveAutoImportPauseMs(0)).toBe(DEFAULT_AUTO_IMPORT_PAUSE_MS);
    });

    test("a negative gap falls back to the default", () => {
        expect(resolveAutoImportPauseMs(-1)).toBe(DEFAULT_AUTO_IMPORT_PAUSE_MS);
    });

    test("a gap that is not a usable number falls back to the default", () => {
        // The value comes from a file a person may have edited, so it can be anything at all.
        expect(resolveAutoImportPauseMs(Number.NaN)).toBe(DEFAULT_AUTO_IMPORT_PAUSE_MS);
        expect(resolveAutoImportPauseMs(Number.POSITIVE_INFINITY)).toBe(DEFAULT_AUTO_IMPORT_PAUSE_MS);
        expect(resolveAutoImportPauseMs("soon" as any)).toBe(DEFAULT_AUTO_IMPORT_PAUSE_MS);
    });
});
