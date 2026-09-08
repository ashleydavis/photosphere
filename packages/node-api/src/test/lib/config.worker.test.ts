import * as os from "os";
import * as path from "path";
import * as fs from "fs/promises";
import yaml from "js-yaml";
import { DEFAULT_AUTO_IMPORT_PAUSE_MS } from "api/src/lib/auto-import-mobile";
import { DEFAULT_SYNC_PAUSE_MS } from "api/src/lib/sync-settings";
import {
    buildConfigYaml,
    readConfigFromStorage,
    readConfigHandler,
    writeConfigHandler,
} from "../../lib/config.worker";

//
// Tests for the mobile config.yaml handlers.
//
// These run against the real filesystem rather than a mock, for the same reason the databases.toml
// tests do: the point of the handlers is the bytes they put on disk. The settings are read by the
// app, by the background import and by the background sync, so what matters is that a file written
// by one is read by the others, not which functions were called.
//
// The handlers reach storage through FileStorage, which resolves relative paths against the process
// working directory on a host and against the app's sandbox root on a device, so the tests run from
// a temporary directory standing in for that sandbox.
//
// Both features share the one file, so what only a shared file can get wrong is covered here too:
// one feature's write erasing the other's settings, and one feature's write making it look as though
// the other had already been chosen.
//

//
// The task context the handlers take. They ignore it, so an empty object suffices.
//
const context: any = {};

//
// The path the tests read and write, relative to the temporary sandbox below.
//
const CONFIG_PATH = "config.yaml";

//
// A temporary working directory standing in for the app's storage sandbox, and the directory the
// test switches back to afterwards.
//
let tempDir: string;
let previousCwd: string;

beforeEach(async () => {
    previousCwd = process.cwd();
    tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "psphere-config-"));
    process.chdir(tempDir);
});

afterEach(async () => {
    process.chdir(previousCwd);
    await fs.rm(tempDir, { recursive: true, force: true });
});

//
// Writes the given text as the config file.
//
async function writeConfigText(text: string): Promise<void> {
    await fs.writeFile(path.join(tempDir, CONFIG_PATH), text, "utf8");
}

//
// Reads the config file back as a parsed document.
//
async function readConfigDocument(): Promise<any> {
    return yaml.load(await fs.readFile(path.join(tempDir, CONFIG_PATH), "utf8"));
}

describe("reading a sandbox with no config file", () => {

    test("reports that neither feature's settings have been written", async () => {
        // The interface needs to tell "nobody has written this yet" from "somebody switched syncing
        // off", because the first is a fresh install to seed and the second is a decision to leave
        // alone, and both read as switched off.
        const result = await readConfigHandler({ configPath: CONFIG_PATH }, context);

        expect(result.syncSettingsWritten).toBe(false);
        expect(result.autoImportSettingsWritten).toBe(false);
    });

    test("yields both loops switched off", async () => {
        // The safe answer, and the whole reason the defaults are what they are: a background loop
        // that cannot read its settings must not start pushing photos over a metered connection.
        const result = await readConfigHandler({ configPath: CONFIG_PATH }, context);

        expect(result.sync.settings.enabled).toBe(false);
        expect(result.sync.settings.onlyOnWifi).toBe(true);
        expect(result.sync.pauseBetweenRunsMs).toBe(DEFAULT_SYNC_PAUSE_MS);
        expect(result.autoImport.settings.enabled).toBe(false);
        expect(result.autoImport.settings.sources).toEqual([]);
        expect(result.autoImport.defaultDatabasePath).toBeUndefined();
        expect(result.autoImport.pauseBetweenRunsMs).toBe(DEFAULT_AUTO_IMPORT_PAUSE_MS);
    });
});

describe("a corrupt config file", () => {

    test("reads as the defaults rather than throwing", async () => {
        // This file is written by the app and never shown to the user, so a copy that cannot be read
        // is a bug somewhere else. Throwing here would take the settings card that could fix it down
        // with it, and reading it as "sync over anything" would spend somebody's mobile data.
        await writeConfigText("sync:\n  enabled: true\n   this: [is not yaml");

        const result = await readConfigHandler({ configPath: CONFIG_PATH }, context);

        expect(result.sync.settings.enabled).toBe(false);
        expect(result.sync.settings.onlyOnWifi).toBe(true);
        expect(result.sync.pauseBetweenRunsMs).toBe(DEFAULT_SYNC_PAUSE_MS);
        expect(result.autoImport.settings.enabled).toBe(false);
        expect(result.autoImport.pauseBetweenRunsMs).toBe(DEFAULT_AUTO_IMPORT_PAUSE_MS);
    });

    test("reports that no section could be read", async () => {
        // Nothing in it parsed, so nothing in it has been chosen: a fresh install must still be
        // seeded rather than left believing its settings were already decided.
        await writeConfigText("not: [valid");

        const result = await readConfigHandler({ configPath: CONFIG_PATH }, context);

        expect(result.syncSettingsWritten).toBe(false);
        expect(result.autoImportSettingsWritten).toBe(false);
    });
});

describe("writing then reading", () => {

    test("round-trips the syncing settings and the pacing", async () => {
        await writeConfigHandler({
            configPath: CONFIG_PATH,
            sync: {
                settings: {
                    enabled: true,
                    onlyOnWifi: false,
                },
                databasePath: "photosphere-default",
                pauseBetweenRunsMs: 60000,
            },
        }, context);

        const result = await readConfigHandler({ configPath: CONFIG_PATH }, context);

        expect(result.sync.settings.enabled).toBe(true);
        expect(result.sync.settings.onlyOnWifi).toBe(false);
        expect(result.sync.databasePath).toBe("photosphere-default");
        expect(result.sync.pauseBetweenRunsMs).toBe(60000);
    });

    test("round-trips the automatic import settings and the default database", async () => {
        await writeConfigHandler({
            configPath: CONFIG_PATH,
            autoImport: {
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
            },
        }, context);

        const result = await readConfigHandler({ configPath: CONFIG_PATH }, context);

        expect(result.autoImport.settings.enabled).toBe(true);
        expect(result.autoImport.settings.sources).toEqual([
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
        expect(result.autoImport.defaultDatabasePath).toBe("photosphere-default");
        expect(result.autoImport.pauseBetweenRunsMs).toBe(5000);
    });

    test("round-trips both sections written together", async () => {
        await writeConfigHandler({
            configPath: CONFIG_PATH,
            autoImport: {
                settings: {
                    enabled: true,
                    sources: [{ type: "device-album", albumId: "all" }],
                },
                defaultDatabasePath: "photosphere-default",
                pauseBetweenRunsMs: 5000,
            },
            sync: {
                settings: {
                    enabled: true,
                    onlyOnWifi: true,
                },
                databasePath: "photosphere-default",
                pauseBetweenRunsMs: 60000,
            },
        }, context);

        const result = await readConfigHandler({ configPath: CONFIG_PATH }, context);

        expect(result.autoImport.settings.enabled).toBe(true);
        expect(result.autoImport.pauseBetweenRunsMs).toBe(5000);
        expect(result.sync.settings.enabled).toBe(true);
        expect(result.sync.pauseBetweenRunsMs).toBe(60000);
    });

    test("a file that is there says so, even when it says both loops are off", async () => {
        await writeConfigHandler({
            configPath: CONFIG_PATH,
            sync: {
                settings: {
                    enabled: false,
                    onlyOnWifi: false,
                },
                pauseBetweenRunsMs: DEFAULT_SYNC_PAUSE_MS,
            },
        }, context);

        const result = await readConfigHandler({ configPath: CONFIG_PATH }, context);

        expect(result.syncSettingsWritten).toBe(true);
        expect(result.sync.settings.enabled).toBe(false);
    });
});

//
// The hazard that only exists now the two features share a file. They are switched on separately and
// their settings cards write independently, so a write that replaced the whole document would take
// the other feature's settings with it.
//
describe("a write of one section leaves the others alone", () => {

    test("writing the syncing settings keeps what automatic import watches", async () => {
        await writeConfigHandler({
            configPath: CONFIG_PATH,
            autoImport: {
                settings: {
                    enabled: true,
                    sources: [{ type: "device-album", albumId: "holiday-album" }],
                },
                defaultDatabasePath: "photosphere-default",
                pauseBetweenRunsMs: 5000,
            },
        }, context);

        await writeConfigHandler({
            configPath: CONFIG_PATH,
            sync: {
                settings: {
                    enabled: true,
                    onlyOnWifi: false,
                },
                pauseBetweenRunsMs: 60000,
            },
        }, context);

        const result = await readConfigHandler({ configPath: CONFIG_PATH }, context);

        expect(result.autoImport.settings.enabled).toBe(true);
        expect(result.autoImport.settings.sources).toEqual([{ type: "device-album", albumId: "holiday-album" }]);
        expect(result.autoImport.defaultDatabasePath).toBe("photosphere-default");
        expect(result.autoImport.pauseBetweenRunsMs).toBe(5000);
        expect(result.sync.settings.enabled).toBe(true);
    });

    test("writing the automatic import settings keeps the syncing settings", async () => {
        await writeConfigHandler({
            configPath: CONFIG_PATH,
            sync: {
                settings: {
                    enabled: true,
                    onlyOnWifi: false,
                },
                databasePath: "the-database-being-synced",
                pauseBetweenRunsMs: 60000,
            },
        }, context);

        await writeConfigHandler({
            configPath: CONFIG_PATH,
            autoImport: {
                settings: {
                    enabled: false,
                    sources: [],
                },
                pauseBetweenRunsMs: 5000,
            },
        }, context);

        const result = await readConfigHandler({ configPath: CONFIG_PATH }, context);

        expect(result.sync.settings.enabled).toBe(true);
        expect(result.sync.settings.onlyOnWifi).toBe(false);
        expect(result.sync.databasePath).toBe("the-database-being-synced");
        expect(result.sync.pauseBetweenRunsMs).toBe(60000);
        expect(result.autoImport.settings.enabled).toBe(false);
    });

    //
    // A desktop installation sharing this file writes sections this task has no notion of at all.
    // Reading before writing is what keeps them.
    //
    test("keeps settings the task knows nothing about, such as the theme and the saved searches", async () => {
        await writeConfigText([
            "theme: dark",
            "developer_mode: true",
            "show_fps_indicator: true",
            "saved_searches:",
            "  - beach",
            "",
        ].join("\n"));

        await writeConfigHandler({
            configPath: CONFIG_PATH,
            sync: {
                settings: {
                    enabled: true,
                    onlyOnWifi: true,
                },
                pauseBetweenRunsMs: 60000,
            },
        }, context);

        const document = await readConfigDocument();

        expect(document.theme).toBe("dark");
        expect(document.developer_mode).toBe(true);
        expect(document.show_fps_indicator).toBe(true);
        expect(document.saved_searches).toEqual(["beach"]);
        expect(document.sync.enabled).toBe(true);
    });
});

//
// Which settings have been chosen is asked per feature, not of the file.
//
// The two used to be files of their own, so "the file is there" answered "have these settings been
// chosen?". With one file it does not: automatic import writing its own section brings the file into
// being, and a fresh install would then be told its syncing settings had already been decided. The
// interface skips its seeding step on that answer, so the phone would sit with syncing switched off
// while both toggles said it was on.
//
describe("whether a feature's settings have been written", () => {

    test("writing only the automatic import settings does not claim the syncing settings were chosen", async () => {
        await writeConfigHandler({
            configPath: CONFIG_PATH,
            autoImport: {
                settings: {
                    enabled: true,
                    sources: [{ type: "device-album", albumId: "all" }],
                },
                pauseBetweenRunsMs: 5000,
            },
        }, context);

        const result = await readConfigHandler({ configPath: CONFIG_PATH }, context);

        expect(result.autoImportSettingsWritten).toBe(true);
        expect(result.syncSettingsWritten).toBe(false);
    });

    test("writing only the syncing settings does not claim the automatic import settings were chosen", async () => {
        await writeConfigHandler({
            configPath: CONFIG_PATH,
            sync: {
                settings: {
                    enabled: true,
                    onlyOnWifi: true,
                },
                pauseBetweenRunsMs: 60000,
            },
        }, context);

        const result = await readConfigHandler({ configPath: CONFIG_PATH }, context);

        expect(result.syncSettingsWritten).toBe(true);
        expect(result.autoImportSettingsWritten).toBe(false);
    });

    test("a file holding only another platform's settings claims neither", async () => {
        await writeConfigText("theme: dark\ndesktop:\n  last_folder: /home/someone/photos\n");

        const result = await readConfigHandler({ configPath: CONFIG_PATH }, context);

        expect(result.syncSettingsWritten).toBe(false);
        expect(result.autoImportSettingsWritten).toBe(false);
    });

    test("both are claimed once both have been written", async () => {
        await writeConfigHandler({
            configPath: CONFIG_PATH,
            autoImport: {
                settings: {
                    enabled: false,
                    sources: [],
                },
                pauseBetweenRunsMs: 5000,
            },
            sync: {
                settings: {
                    enabled: false,
                    onlyOnWifi: true,
                },
                pauseBetweenRunsMs: 60000,
            },
        }, context);

        const result = await readConfigHandler({ configPath: CONFIG_PATH }, context);

        expect(result.syncSettingsWritten).toBe(true);
        expect(result.autoImportSettingsWritten).toBe(true);
    });
});

describe("the file on disk", () => {

    test("is YAML with snake_case keys nested by feature", async () => {
        // Asserted on the file itself, because anything else that opens it (a smoke test seeding
        // settings from outside the app, a person looking at what their phone is doing) reads these
        // names rather than the TypeScript ones.
        await writeConfigHandler({
            configPath: CONFIG_PATH,
            autoImport: {
                settings: {
                    enabled: true,
                    sources: [{ type: "device-album", albumId: "all" }],
                },
                defaultDatabasePath: "photosphere-default",
                pauseBetweenRunsMs: 30000,
            },
            sync: {
                settings: {
                    enabled: true,
                    onlyOnWifi: true,
                },
                pauseBetweenRunsMs: 300000,
            },
        }, context);

        const document = await readConfigDocument();

        expect(document.auto_import.enabled).toBe(true);
        expect(document.auto_import.default_database_path).toBe("photosphere-default");
        expect(document.auto_import.pause_between_runs_ms).toBe(30000);
        expect(document.auto_import.sources).toEqual([
            {
                type: "device-album",
                album_id: "all",
            },
        ]);
        expect(document.sync.enabled).toBe(true);
        expect(document.sync.only_on_wifi).toBe(true);
        expect(document.sync.pause_between_runs_ms).toBe(300000);
    });
});

describe("values a hand-edited file may hold", () => {

    test("a gap of zero or less falls back to the default rather than spinning", async () => {
        // A gap of zero is a loop that starts a fresh pass the instant the last one ended, which on a
        // phone is a flat battery rather than a fast backup. The value can only get here by hand, so
        // it is corrected on the way in and on the way out.
        await writeConfigText("auto_import:\n  enabled: true\n  pause_between_runs_ms: 0\nsync:\n  enabled: true\n  pause_between_runs_ms: 0\n");

        const zeroGap = await readConfigHandler({ configPath: CONFIG_PATH }, context);
        expect(zeroGap.autoImport.pauseBetweenRunsMs).toBe(DEFAULT_AUTO_IMPORT_PAUSE_MS);
        expect(zeroGap.sync.pauseBetweenRunsMs).toBe(DEFAULT_SYNC_PAUSE_MS);

        await writeConfigText("auto_import:\n  pause_between_runs_ms: -1000\nsync:\n  pause_between_runs_ms: -1000\n");

        const negativeGap = await readConfigHandler({ configPath: CONFIG_PATH }, context);
        expect(negativeGap.autoImport.pauseBetweenRunsMs).toBe(DEFAULT_AUTO_IMPORT_PAUSE_MS);
        expect(negativeGap.sync.pauseBetweenRunsMs).toBe(DEFAULT_SYNC_PAUSE_MS);
    });

    test("a value that is not a boolean is not taken as one", async () => {
        // The string "false" is truthy, so coercing it would switch syncing on for somebody who
        // wrote the opposite.
        await writeConfigText('sync:\n  enabled: "false"\n  only_on_wifi: "no"\n');

        const result = await readConfigHandler({ configPath: CONFIG_PATH }, context);

        expect(result.sync.settings.enabled).toBe(false);
        expect(result.sync.settings.onlyOnWifi).toBe(true);
    });

    test("a missing setting falls back rather than being left undefined", async () => {
        await writeConfigText("sync:\n  enabled: true\n");

        const result = await readConfigHandler({ configPath: CONFIG_PATH }, context);

        expect(result.sync.settings.enabled).toBe(true);
        expect(result.sync.settings.onlyOnWifi).toBe(true);
    });

    test("a malformed source is dropped rather than taken as a place to watch", async () => {
        await writeConfigText([
            "auto_import:",
            "  enabled: true",
            "  sources:",
            "    - type: device-album",
            "      album_id: all",
            "    - type: folder",
            "",
        ].join("\n"));

        const result = await readConfigHandler({ configPath: CONFIG_PATH }, context);

        expect(result.autoImport.settings.sources).toEqual([
            {
                type: "device-album",
                albumId: "all",
            },
        ]);
    });
});

describe("buildConfigYaml", () => {

    test("produces a document the reader reads back as the input", async () => {
        // buildConfigYaml is what a host-side script uses to seed a device's settings, so it has to
        // produce exactly the file the handler would have written.
        const rendered = buildConfigYaml({
            autoImport: {
                settings: {
                    enabled: true,
                    sources: [],
                },
                defaultDatabasePath: undefined,
                pauseBetweenRunsMs: 1000,
            },
            sync: {
                settings: {
                    enabled: true,
                    onlyOnWifi: false,
                },
                databasePath: "photosphere-default",
                pauseBetweenRunsMs: 120000,
            },
        });

        await writeConfigText(rendered);

        const { config: contents } = await readConfigFromStorage(CONFIG_PATH);

        expect(contents.autoImport.settings.enabled).toBe(true);
        expect(contents.autoImport.defaultDatabasePath).toBeUndefined();
        expect(contents.autoImport.pauseBetweenRunsMs).toBe(1000);
        expect(contents.sync.settings.enabled).toBe(true);
        expect(contents.sync.settings.onlyOnWifi).toBe(false);
        expect(contents.sync.databasePath).toBe("photosphere-default");
        expect(contents.sync.pauseBetweenRunsMs).toBe(120000);
    });
});

describe("bad input to the handlers", () => {

    test("a write with no config path fails rather than writing somewhere else", async () => {
        await expect(writeConfigHandler({
            configPath: "",
            sync: {
                settings: {
                    enabled: true,
                    onlyOnWifi: true,
                },
                pauseBetweenRunsMs: DEFAULT_SYNC_PAUSE_MS,
            },
        }, context)).rejects.toThrow("configPath is required");
    });

    test("a read with no config path fails rather than reading somewhere else", async () => {
        await expect(readConfigHandler({ configPath: "" }, context)).rejects.toThrow("configPath is required");
    });

    //
    // A write with no section at all would silently rewrite the file with what it already held,
    // which looks like it worked and changes nothing. It is always a caller bug, so it is loud.
    //
    test("a write with nothing to write fails rather than doing nothing quietly", async () => {
        await expect(writeConfigHandler({ configPath: CONFIG_PATH }, context))
            .rejects.toThrow(/nothing to write/);
    });

    test("a setting with no key fails rather than being written under an empty name", async () => {
        await expect(writeConfigHandler({ configPath: CONFIG_PATH, entries: [{ key: "", value: true }] }, context))
            .rejects.toThrow(/no key/);
    });
});

//
// The settings the interface names, which is how a phone reads and writes what the desktop app and
// the CLI keep in this same file. Each one goes to the section the format puts it in. A key this file
// does not hold is not this handler's business: the routing sends it to state.yaml instead.
//
describe("the settings the interface names", () => {

    test("a setting the format declares is written into its own section and read back by name", async () => {
        await writeConfigHandler({ configPath: CONFIG_PATH, entries: [{ key: "theme", value: "dark" }] }, context);

        expect((await readConfigDocument()).theme).toBe("dark");
        expect((await readConfigHandler({ configPath: CONFIG_PATH }, context)).settings.theme).toBe("dark");
    });

    test("the searches the user saved are written at the top level and read back by name", async () => {
        await writeConfigHandler({
            configPath: CONFIG_PATH,
            entries: [{ key: "savedSearches", value: ["beach", "dogs"] }],
        }, context);

        expect((await readConfigDocument()).saved_searches).toEqual(["beach", "dogs"]);
        expect((await readConfigHandler({ configPath: CONFIG_PATH }, context)).settings.savedSearches)
            .toEqual(["beach", "dogs"]);
    });

    test("an entry with no value clears the setting rather than leaving it as it was", async () => {
        await writeConfigHandler({ configPath: CONFIG_PATH, entries: [{ key: "theme", value: "dark" }] }, context);
        await writeConfigHandler({ configPath: CONFIG_PATH, entries: [{ key: "theme" }] }, context);

        expect((await readConfigDocument()).theme).toBeUndefined();
        expect((await readConfigHandler({ configPath: CONFIG_PATH }, context)).settings.theme).toBeUndefined();
    });

    test("writing a setting leaves a feature's settings exactly as they were", async () => {
        await writeConfigHandler({
            configPath: CONFIG_PATH,
            sync: {
                settings: {
                    enabled: true,
                    onlyOnWifi: false,
                },
                databasePath: "the-database",
                pauseBetweenRunsMs: 90000,
            },
        }, context);

        await writeConfigHandler({ configPath: CONFIG_PATH, entries: [{ key: "theme", value: "light" }] }, context);

        const result = await readConfigHandler({ configPath: CONFIG_PATH }, context);
        expect(result.sync.settings.enabled).toBe(true);
        expect(result.sync.settings.onlyOnWifi).toBe(false);
        expect(result.sync.databasePath).toBe("the-database");
        expect(result.sync.pauseBetweenRunsMs).toBe(90000);
        expect(result.settings.theme).toBe("light");
    });

    test("writing a setting does not make it look as though syncing had been decided", async () => {
        // A fresh install seeds syncing on, and only skips that when the file says syncing has been
        // chosen already. An empty sync section left behind by an unrelated write would say exactly
        // that, and the phone would sit with syncing off and its toggles saying on.
        await writeConfigHandler({ configPath: CONFIG_PATH, entries: [{ key: "theme", value: "light" }] }, context);

        const result = await readConfigHandler({ configPath: CONFIG_PATH }, context);
        expect(result.syncSettingsWritten).toBe(false);
        expect(result.autoImportSettingsWritten).toBe(false);
        expect((await readConfigDocument()).sync).toBeUndefined();
    });

    test("a setting the state file holds is not answered from here", async () => {
        // The routing sends it to state.yaml, so config.yaml never carries it and reading it back
        // through this handler has to come up empty rather than finding a stale copy.
        await writeConfigHandler({ configPath: CONFIG_PATH, entries: [{ key: "theme", value: "dark" }] }, context);

        const settings = (await readConfigHandler({ configPath: CONFIG_PATH }, context)).settings;
        expect(settings.gallerySort).toBeUndefined();
        expect(settings["sidebar-collapsed-databases"]).toBeUndefined();
    });
});
