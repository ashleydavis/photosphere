import * as os from "os";
import * as path from "path";
import * as fs from "fs/promises";
import { parse as parseToml } from "smol-toml";
import { DEFAULT_AUTO_IMPORT_SETTINGS } from "api/src/lib/auto-import-settings";
import { DEFAULT_AUTO_IMPORT_PAUSE_MS } from "api/src/lib/auto-import-mobile";
import {
    buildAutoImportConfigToml,
    readAutoImportConfigFile,
    readAutoImportConfigHandler,
    writeAutoImportConfigHandler,
} from "../../lib/auto-import-config.worker";

//
// Tests for the mobile auto-import.toml handlers.
//
// These run against the real filesystem rather than a mock, for the same reason the databases.toml
// tests do: the point of the handlers is the bytes they put on disk. The settings are read by the
// app and by the background import, so what matters is that a file written by one is read by the
// other, not which functions were called.
//
// The handlers reach storage through FileStorage, which resolves relative paths against the process
// working directory on a host and against the app's sandbox root on a device, so the tests run from
// a temporary directory standing in for that sandbox.
//

//
// The task context the handlers take. They ignore it, so an empty object suffices.
//
const context: any = {};

//
// The path the tests read and write, relative to the temporary sandbox below.
//
const CONFIG_PATH = "auto-import.toml";

//
// A temporary working directory standing in for the app's storage sandbox, and the directory the
// test switches back to afterwards.
//
let tempDir: string;
let previousCwd: string;

beforeEach(async () => {
    previousCwd = process.cwd();
    tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "psphere-auto-import-config-"));
    process.chdir(tempDir);
});

afterEach(async () => {
    process.chdir(previousCwd);
    await fs.rm(tempDir, { recursive: true, force: true });
});

describe("mobile auto-import.toml", () => {

    test("reading a file that does not exist yields the defaults", async () => {
        // A fresh install has no file, and that must read as "automatic import is off" rather than
        // fail: the app cannot even show the settings card if reading the settings throws.
        const result = await readAutoImportConfigHandler({ configPath: CONFIG_PATH }, context);

        expect(result.settings.enabled).toBe(false);
        expect(result.settings.sources).toEqual([]);
        expect(result.defaultDatabasePath).toBeUndefined();
        expect(result.pauseBetweenRunsMs).toBe(DEFAULT_AUTO_IMPORT_PAUSE_MS);
    });

    test("a file that will not parse reads as the defaults rather than throwing", async () => {
        // This file is written by the app and never shown to the user, so a copy that cannot be read
        // is a bug somewhere else. Throwing here would take automatic import down with it, and with
        // it the settings card that could switch it off.
        await fs.writeFile(path.join(tempDir, CONFIG_PATH), "this is not = = toml [[[", "utf8");

        const result = await readAutoImportConfigHandler({ configPath: CONFIG_PATH }, context);

        expect(result.settings.enabled).toBe(false);
        expect(result.pauseBetweenRunsMs).toBe(DEFAULT_AUTO_IMPORT_PAUSE_MS);
    });

    test("writing then reading round-trips the settings and the default database", async () => {
        await writeAutoImportConfigHandler({
            configPath: CONFIG_PATH,
            settings: {
                enabled: true,
                sources: [
                    {
                        type: "device-album",
                        albumId: "all",
                    },
                    {
                        type: "folder",
                        path: "/photos/holiday",
                        recurse: false,
                    },
                ],
            },
            defaultDatabasePath: "photosphere-default",
            pauseBetweenRunsMs: 5000,
        }, context);

        const result = await readAutoImportConfigHandler({ configPath: CONFIG_PATH }, context);

        expect(result.settings.enabled).toBe(true);
        expect(result.settings.sources).toEqual([
            {
                type: "device-album",
                albumId: "all",
            },
            {
                type: "folder",
                path: "/photos/holiday",
                recurse: false,
            },
        ]);
        expect(result.defaultDatabasePath).toBe("photosphere-default");
        expect(result.pauseBetweenRunsMs).toBe(5000);
    });

    test("the file is TOML with snake_case keys", async () => {
        // Asserted on the file itself, because anything else that opens it (a smoke test seeding
        // settings from outside the app, a person looking at what their phone is doing) reads these
        // names rather than the TypeScript ones.
        await writeAutoImportConfigHandler({
            configPath: CONFIG_PATH,
            settings: {
                enabled: true,
                sources: [
                    {
                        type: "device-album",
                        albumId: "all",
                    },
                ],
            },
            defaultDatabasePath: "photosphere-default",
            pauseBetweenRunsMs: 30000,
        }, context);

        const toml: any = parseToml(await fs.readFile(path.join(tempDir, CONFIG_PATH), "utf8"));

        expect(toml.enabled).toBe(true);
        expect(toml.default_database_path).toBe("photosphere-default");
        expect(toml.pause_between_runs_ms).toBe(30000);
        expect(toml.sources).toEqual([
            {
                type: "device-album",
                album_id: "all",
            },
        ]);
    });

    test("a gap of zero or less falls back to the default rather than spinning", async () => {
        // A gap of zero is a loop that starts a fresh pass the instant the last one ended, which on a
        // phone is a flat battery rather than a fast backup. The value can only get here by hand, so
        // it is corrected on the way in and on the way out.
        await fs.writeFile(
            path.join(tempDir, CONFIG_PATH),
            "enabled = true\npause_between_runs_ms = 0\n",
            "utf8");

        const zeroGap = await readAutoImportConfigHandler({ configPath: CONFIG_PATH }, context);
        expect(zeroGap.pauseBetweenRunsMs).toBe(DEFAULT_AUTO_IMPORT_PAUSE_MS);

        await fs.writeFile(
            path.join(tempDir, CONFIG_PATH),
            "enabled = true\npause_between_runs_ms = -1000\n",
            "utf8");

        const negativeGap = await readAutoImportConfigHandler({ configPath: CONFIG_PATH }, context);
        expect(negativeGap.pauseBetweenRunsMs).toBe(DEFAULT_AUTO_IMPORT_PAUSE_MS);
    });

    test("a malformed source is dropped rather than taken as a place to watch", async () => {
        await fs.writeFile(
            path.join(tempDir, CONFIG_PATH),
            [
                "enabled = true",
                "",
                "[[sources]]",
                'type = "device-album"',
                'album_id = "all"',
                "",
                "[[sources]]",
                'type = "folder"',
                "",
            ].join("\n"),
            "utf8");

        const result = await readAutoImportConfigHandler({ configPath: CONFIG_PATH }, context);

        expect(result.settings.sources).toEqual([
            {
                type: "device-album",
                albumId: "all",
            },
        ]);
    });

    test("the rendered TOML is what the reader reads back", async () => {
        // buildAutoImportConfigToml is what a host-side script uses to seed a device's settings, so
        // it has to produce exactly the file the handler would have written.
        const rendered = buildAutoImportConfigToml({
            settings: {
                enabled: true,
                sources: [],
            },
            defaultDatabasePath: undefined,
            pauseBetweenRunsMs: 1000,
        });

        await fs.writeFile(path.join(tempDir, CONFIG_PATH), rendered, "utf8");

        const contents = await readAutoImportConfigFile(CONFIG_PATH);

        expect(contents.settings.enabled).toBe(true);
        expect(contents.defaultDatabasePath).toBeUndefined();
        expect(contents.pauseBetweenRunsMs).toBe(1000);
    });
});
