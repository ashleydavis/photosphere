import * as path from "path";
import { IDesktopConfig } from "../../lib/desktop-config";
import {
    DEFAULT_DATABASE_FOLDER_NAME,
    foldersAsSources,
    getDefaultDatabasePath,
    planDesktopAutoImport,
} from "../../lib/auto-import-desktop";

const APP_DATA_PATH = "/home/someone/.config/Photosphere";
const PHOTO_FOLDERS = ["/home/someone/Pictures"];

describe("planDesktopAutoImport", () => {

    test("does not run when automatic import has never been switched on", () => {
        const plan = planDesktopAutoImport({}, PHOTO_FOLDERS, APP_DATA_PATH);

        expect(plan.shouldRun).toBe(false);
    });

    test("does not run when automatic import is switched off", () => {
        const config: IDesktopConfig = { autoImportEnabled: false };

        expect(planDesktopAutoImport(config, PHOTO_FOLDERS, APP_DATA_PATH).shouldRun).toBe(false);
    });

    test("runs when automatic import is switched on", () => {
        const config: IDesktopConfig = { autoImportEnabled: true };

        expect(planDesktopAutoImport(config, PHOTO_FOLDERS, APP_DATA_PATH).shouldRun).toBe(true);
    });

    test("does not run when there is nothing at all to watch", () => {
        const config: IDesktopConfig = { autoImportEnabled: true };

        const plan = planDesktopAutoImport(config, [], APP_DATA_PATH);

        expect(plan.shouldRun).toBe(false);
        expect(plan.settings.sources).toEqual([]);
    });

    test("falls back to the operating system's photo folders when none are configured", () => {
        const config: IDesktopConfig = { autoImportEnabled: true };

        const plan = planDesktopAutoImport(config, ["/home/someone/Pictures", "/home/someone/Camera"], APP_DATA_PATH);

        expect(plan.settings.sources).toEqual([
            { type: "folder", path: "/home/someone/Pictures", recurse: true },
            { type: "folder", path: "/home/someone/Camera", recurse: true },
        ]);
    });

    test("uses the configured places rather than the operating system's", () => {
        const config: IDesktopConfig = {
            autoImportEnabled: true,
            autoImportSources: [{ type: "folder", path: "/mnt/photos", recurse: false }],
        };

        const plan = planDesktopAutoImport(config, PHOTO_FOLDERS, APP_DATA_PATH);

        expect(plan.settings.sources).toEqual([{ type: "folder", path: "/mnt/photos", recurse: false }]);
    });

    test("drops a malformed stored source rather than failing to start", () => {
        const config = {
            autoImportEnabled: true,
            autoImportSources: [{ type: "folder" }, { type: "folder", path: "/mnt/photos", recurse: true }],
        } as any;

        const plan = planDesktopAutoImport(config, PHOTO_FOLDERS, APP_DATA_PATH);

        expect(plan.settings.sources).toEqual([{ type: "folder", path: "/mnt/photos", recurse: true }]);
    });

    test("chooses the default database location when none has been chosen", () => {
        const plan = planDesktopAutoImport({ autoImportEnabled: true }, PHOTO_FOLDERS, APP_DATA_PATH);

        expect(plan.isNewDefault).toBe(true);
        expect(plan.databasePath).toBe(path.join(APP_DATA_PATH, DEFAULT_DATABASE_FOLDER_NAME));
    });

    test("uses the chosen default database when there is one", () => {
        const config: IDesktopConfig = { autoImportEnabled: true, defaultDatabasePath: "/home/someone/my-photos" };

        const plan = planDesktopAutoImport(config, PHOTO_FOLDERS, APP_DATA_PATH);

        expect(plan.isNewDefault).toBe(false);
        expect(plan.databasePath).toBe("/home/someone/my-photos");
    });

    test("an empty stored default counts as none chosen", () => {
        const config: IDesktopConfig = { autoImportEnabled: true, defaultDatabasePath: "" };

        const plan = planDesktopAutoImport(config, PHOTO_FOLDERS, APP_DATA_PATH);

        expect(plan.isNewDefault).toBe(true);
        expect(plan.databasePath).toBe(path.join(APP_DATA_PATH, DEFAULT_DATABASE_FOLDER_NAME));
    });

    test("the pacing is the shared default, not something the config invented", () => {
        const plan = planDesktopAutoImport({ autoImportEnabled: true }, PHOTO_FOLDERS, APP_DATA_PATH);

        expect(plan.settings.backfillItemsPerMinute).toBe(60);
    });
});

describe("foldersAsSources", () => {

    test("turns folder paths into recursive folder sources", () => {
        expect(foldersAsSources(["/one", "/two"])).toEqual([
            { type: "folder", path: "/one", recurse: true },
            { type: "folder", path: "/two", recurse: true },
        ]);
    });

    test("no folders means no sources", () => {
        expect(foldersAsSources([])).toEqual([]);
    });
});

describe("getDefaultDatabasePath", () => {

    test("sits under the application data directory", () => {
        expect(getDefaultDatabasePath("/data")).toBe(path.join("/data", DEFAULT_DATABASE_FOLDER_NAME));
    });
});
