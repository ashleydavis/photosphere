import * as os from "os";
import * as path from "path";
import * as fs from "fs/promises";
import { DEFAULT_DATABASE_DISPLAY_NAME } from "api/src/lib/auto-import-mobile";
import { AUTO_IMPORT_CONFIG_PATH, DATABASES_CONFIG_PATH } from "api/src/lib/mobile-config-paths";
import { buildAutoImportConfigToml, readAutoImportConfigHandler } from "node-api/src/lib/auto-import-config.worker";
import { buildDatabasesConfigToml, readDatabasesConfigHandler } from "node-api/src/lib/databases-config.worker";
import { recordDefaultDatabaseHandler } from "../../lib/record-default-database.worker";

//
// Tests for the task that records a database the background import has just created.
//
// The two writes it makes have to happen together: a database recorded as the default but missing
// from the list is one the user cannot open, and a database in the list that is not recorded as the
// default is created again on the next pass, on top of the one that is already there.
//
// It runs against the real filesystem, from a temporary directory standing in for the app's storage
// sandbox, because the two files are what it is for.
//

//
// The task context the handlers take. They ignore it, so an empty object suffices.
//
const context: any = {};

//
// A temporary working directory standing in for the app's storage sandbox, and the directory the
// test switches back to afterwards.
//
let tempDir: string;
let previousCwd: string;

beforeEach(async () => {
    previousCwd = process.cwd();
    tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "psphere-record-default-"));
    process.chdir(tempDir);
});

afterEach(async () => {
    process.chdir(previousCwd);
    await fs.rm(tempDir, { recursive: true, force: true });
});

describe("record-default-database", () => {

    test("records the database as the default and adds it to the database list", async () => {
        await fs.writeFile(
            path.join(tempDir, AUTO_IMPORT_CONFIG_PATH),
            buildAutoImportConfigToml({
                settings: {
                    enabled: true,
                    sources: [{ type: "device-album", albumId: "all" }],
                },
                defaultDatabasePath: undefined,
                pauseBetweenRunsMs: 5000,
            }),
            "utf8");

        await recordDefaultDatabaseHandler({ databasePath: "photosphere-default" }, context);

        const settings = await readAutoImportConfigHandler({ configPath: AUTO_IMPORT_CONFIG_PATH }, context);
        expect(settings.defaultDatabasePath).toBe("photosphere-default");

        const databases = await readDatabasesConfigHandler({ configPath: DATABASES_CONFIG_PATH }, context);
        expect(databases.databases).toEqual([
            {
                name: DEFAULT_DATABASE_DISPLAY_NAME,
                description: "",
                path: "photosphere-default",
            },
        ]);
    });

    test("leaves the rest of the settings exactly as it found them", async () => {
        // The pass that creates the database runs while the user may be changing the settings, and
        // this write must not undo what they chose.
        await fs.writeFile(
            path.join(tempDir, AUTO_IMPORT_CONFIG_PATH),
            buildAutoImportConfigToml({
                settings: {
                    enabled: true,
                    sources: [{ type: "device-album", albumId: "holiday-album" }],
                },
                defaultDatabasePath: undefined,
                pauseBetweenRunsMs: 1500,
            }),
            "utf8");

        await recordDefaultDatabaseHandler({ databasePath: "photosphere-default" }, context);

        const settings = await readAutoImportConfigHandler({ configPath: AUTO_IMPORT_CONFIG_PATH }, context);
        expect(settings.settings.enabled).toBe(true);
        expect(settings.settings.sources).toEqual([{ type: "device-album", albumId: "holiday-album" }]);
        expect(settings.pauseBetweenRunsMs).toBe(1500);
    });

    test("keeps the databases the user already has", async () => {
        await fs.writeFile(
            path.join(tempDir, DATABASES_CONFIG_PATH),
            buildDatabasesConfigToml(
                [{ name: "Holiday", description: "Trip photos", path: "holiday" }],
                ["Holiday"],
                undefined),
            "utf8");

        await recordDefaultDatabaseHandler({ databasePath: "photosphere-default" }, context);

        const databases = await readDatabasesConfigHandler({ configPath: DATABASES_CONFIG_PATH }, context);
        expect(databases.databases.map(entry => entry.path)).toEqual(["holiday", "photosphere-default"]);
        expect(databases.recentDatabaseNames).toEqual(["Holiday"]);
    });

    test("recording the same database twice does not list it twice", async () => {
        // A pass can be interrupted after the database is recorded and before the import finishes, so
        // the next pass may record it again.
        await recordDefaultDatabaseHandler({ databasePath: "photosphere-default" }, context);
        await recordDefaultDatabaseHandler({ databasePath: "photosphere-default" }, context);

        const databases = await readDatabasesConfigHandler({ configPath: DATABASES_CONFIG_PATH }, context);
        expect(databases.databases.map(entry => entry.path)).toEqual(["photosphere-default"]);
    });

    test("a missing database path is refused rather than recorded as nothing", async () => {
        await expect(recordDefaultDatabaseHandler({ databasePath: "" }, context)).rejects.toThrow("databasePath is required");
    });
});
