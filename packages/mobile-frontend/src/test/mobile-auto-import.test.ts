import { DEFAULT_AUTO_IMPORT_SETTINGS, IAutoImportSettings } from "api/src/lib/auto-import-settings";
import {
    DEFAULT_DATABASE_FOLDER_NAME,
    WHOLE_LIBRARY_SOURCES,
    planMobileAutoImport,
} from "../lib/mobile-auto-import";

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

    test("cleanup is off unless it was switched on", () => {
        expect(planMobileAutoImport(settingsWith({}), undefined).settings.cleanupEnabled).toBe(false);
        expect(planMobileAutoImport(settingsWith({ cleanupEnabled: true }), undefined).settings.cleanupEnabled).toBe(true);
    });

    test("the pacing and poll interval are the shared defaults, not something the settings invented", () => {
        const plan = planMobileAutoImport(settingsWith({}), undefined);

        expect(plan.settings.backfillItemsPerMinute).toBe(60);
        expect(plan.settings.pollIntervalMs).toBe(30000);
    });

    test("the default database has the same name as the desktop one", () => {
        // A user with both should see the same database name, and a support answer about one should
        // apply to the other.
        expect(DEFAULT_DATABASE_FOLDER_NAME).toBe("photosphere-default");
    });
});
