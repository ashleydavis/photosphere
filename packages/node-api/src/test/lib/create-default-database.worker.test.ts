import * as os from "os";
import * as path from "path";
import * as fs from "fs/promises";
import { DEFAULT_DATABASE_DISPLAY_NAME } from "api/src/lib/auto-import-mobile";
import { buildConfigYaml, readConfigHandler } from "../../lib/config.worker";
import { buildDatabasesConfigToml, readDatabasesConfigHandler } from "../../lib/databases-config.worker";
import { checkDatabaseExists } from "../../lib/media-file-database";
import { createDefaultDatabaseHandler } from "../../lib/create-default-database.worker";

//
// Tests for the task that creates the default database and records it. Every platform runs this one,
// so what a default database is cannot differ between them.
//
// The three things it does have to happen together: a database recorded as the default but missing
// from the list is one the user cannot open, and a database that exists but is recorded nowhere is
// created again on the next pass, on top of the one that is already there.
//
// It runs against the real filesystem, from a temporary directory standing in for the app's storage
// sandbox, because a real database and the two files are what it is for.
//

//
// The task context. The database it creates is stamped with the identifiers from here. The
// identifier is a real UUID because the database's merkle tree is written with it packed into
// sixteen bytes, which a made-up string cannot be.
//
const context: any = {
    uuidGenerator: {
        generate: () => "6f1e2c3a-4b5d-4e7f-8a9b-0c1d2e3f4a5b",
    },
    timestampProvider: {
        now: () => 0,
        dateNow: () => new Date(0),
    },
};

//
// A temporary working directory standing in for the app's storage sandbox, and the directory the
// test switches back to afterwards.
//
let tempDir: string;
let previousCwd: string;

beforeEach(async () => {
    previousCwd = process.cwd();
    tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "psphere-create-default-"));
    process.chdir(tempDir);
});

afterEach(async () => {
    process.chdir(previousCwd);
    await fs.rm(tempDir, { recursive: true, force: true });
});

describe("create-default-database", () => {

    test("creates a real database at the path", async () => {
        await createDefaultDatabaseHandler({ databasePath: "photosphere-default", configPath: "config.yaml", databasesConfigPath: "databases.toml" }, context);

        expect(await checkDatabaseExists(path.join(tempDir, "photosphere-default"))).toBe(true);
    });

    test("records the database as the default and adds it to the database list", async () => {
        await fs.writeFile(
            path.join(tempDir, "config.yaml"),
            buildConfigYaml({
                autoImport: {
                    settings: {
                        enabled: true,
                        sources: [{ type: "device-album", albumId: "all" }],
                    },
                    defaultDatabasePath: undefined,
                    pauseBetweenRunsMs: 5000,
                },
                sync: {
                    settings: {
                        enabled: false,
                        onlyOnWifi: true,
                    },
                    databasePath: undefined,
                    pauseBetweenRunsMs: 300000,
                },
            }),
            "utf8");

        await createDefaultDatabaseHandler({ databasePath: "photosphere-default", configPath: "config.yaml", databasesConfigPath: "databases.toml" }, context);

        const settings = await readConfigHandler({ configPath: "config.yaml" }, context);
        expect(settings.autoImport.defaultDatabasePath).toBe("photosphere-default");

        const databases = await readDatabasesConfigHandler({ configPath: "databases.toml" }, context);
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
            path.join(tempDir, "config.yaml"),
            buildConfigYaml({
                autoImport: {
                    settings: {
                        enabled: true,
                        sources: [{ type: "device-album", albumId: "holiday-album" }],
                    },
                    defaultDatabasePath: undefined,
                    pauseBetweenRunsMs: 1500,
                },
                sync: {
                    settings: {
                        enabled: true,
                        onlyOnWifi: false,
                    },
                    databasePath: "a-database-the-user-opened",
                    pauseBetweenRunsMs: 90000,
                },
            }),
            "utf8");

        await createDefaultDatabaseHandler({ databasePath: "photosphere-default", configPath: "config.yaml", databasesConfigPath: "databases.toml" }, context);

        const settings = await readConfigHandler({ configPath: "config.yaml" }, context);
        expect(settings.autoImport.settings.enabled).toBe(true);
        expect(settings.autoImport.settings.sources).toEqual([{ type: "device-album", albumId: "holiday-album" }]);
        expect(settings.autoImport.pauseBetweenRunsMs).toBe(1500);

        // The syncing settings share the file and must survive this write untouched.
        expect(settings.sync.settings.enabled).toBe(true);
        expect(settings.sync.settings.onlyOnWifi).toBe(false);
        expect(settings.sync.databasePath).toBe("a-database-the-user-opened");
        expect(settings.sync.pauseBetweenRunsMs).toBe(90000);
    });

    test("keeps the databases the user already has", async () => {
        await fs.writeFile(
            path.join(tempDir, "databases.toml"),
            buildDatabasesConfigToml(
                [{ name: "Holiday", description: "Trip photos", path: "holiday" }],
                ["Holiday"],
                undefined),
            "utf8");

        await createDefaultDatabaseHandler({ databasePath: "photosphere-default", configPath: "config.yaml", databasesConfigPath: "databases.toml" }, context);

        const databases = await readDatabasesConfigHandler({ configPath: "databases.toml" }, context);
        expect(databases.databases.map(entry => entry.path)).toEqual(["holiday", "photosphere-default"]);
        expect(databases.recentDatabaseNames).toEqual(["Holiday"]);
    });

    test("recording the same database twice does not list it twice", async () => {
        // A pass can be interrupted after the database is recorded and before the import finishes, so
        // the next pass may record it again.
        await createDefaultDatabaseHandler({ databasePath: "photosphere-default", configPath: "config.yaml", databasesConfigPath: "databases.toml" }, context);
        await createDefaultDatabaseHandler({ databasePath: "photosphere-default", configPath: "config.yaml", databasesConfigPath: "databases.toml" }, context);

        const databases = await readDatabasesConfigHandler({ configPath: "databases.toml" }, context);
        expect(databases.databases.map(entry => entry.path)).toEqual(["photosphere-default"]);
    });

    test("a missing database path is refused rather than recorded as nothing", async () => {
        await expect(createDefaultDatabaseHandler({ databasePath: "", configPath: "config.yaml", databasesConfigPath: "databases.toml" }, context)).rejects.toThrow("databasePath is required");
    });
});
