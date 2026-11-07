import yaml from "js-yaml";
import {
    buildConfigYaml,
    configFileToYaml,
    defaultConfigFile,
    parseConfigYaml,
    sectionsPresent,
    yamlToConfigFile,
    type IConfigFile,
    type IYamlConfigFile,
} from "../../lib/config-format";
import { DEFAULT_AUTO_IMPORT_PAUSE_MS } from "api/src/lib/auto-import-mobile";
import { DEFAULT_SYNC_PAUSE_MS } from "api/src/lib/sync-settings";

describe("yamlToConfigFile", () => {

    test("an absent document returns the defaults with syncing and automatic import switched off", () => {
        const config = yamlToConfigFile(undefined);

        expect(config.autoImport.settings.enabled).toBe(false);
        expect(config.autoImport.settings.sources).toEqual([]);
        expect(config.autoImport.defaultDatabasePath).toBeUndefined();
        expect(config.autoImport.pauseBetweenRunsMs).toBe(DEFAULT_AUTO_IMPORT_PAUSE_MS);
        expect(config.sync.settings.enabled).toBe(false);
        expect(config.sync.settings.onlyOnWifi).toBe(true);
        expect(config.sync.databasePath).toBeUndefined();
        expect(config.sync.pauseBetweenRunsMs).toBe(DEFAULT_SYNC_PAUSE_MS);
        expect(config.theme).toBeUndefined();
        expect(config.developerMode).toBeUndefined();
        expect(config.showFpsIndicator).toBeUndefined();
        expect(config.savedSearches).toBeUndefined();
    });

    test("a document with only a sync section leaves the other sections at their defaults", () => {
        const config = yamlToConfigFile({
            sync: {
                enabled: true,
                only_on_wifi: false,
                database_path: "photosphere-default",
                pause_between_runs_ms: 5000,
            },
        });

        expect(config.sync.settings.enabled).toBe(true);
        expect(config.sync.settings.onlyOnWifi).toBe(false);
        expect(config.sync.databasePath).toBe("photosphere-default");
        expect(config.sync.pauseBetweenRunsMs).toBe(5000);

        expect(config.autoImport.settings.enabled).toBe(false);
        expect(config.autoImport.settings.sources).toEqual([]);
        expect(config.autoImport.pauseBetweenRunsMs).toBe(DEFAULT_AUTO_IMPORT_PAUSE_MS);
    });

    test("a document with only an auto_import section leaves the other sections at their defaults", () => {
        const config = yamlToConfigFile({
            auto_import: {
                enabled: true,
                default_database_path: "photosphere-default",
                pause_between_runs_ms: 5000,
                cleanup_enabled: true,
                sources: [
                    {
                        type: "device-album",
                        album_id: "all",
                    },
                ],
            },
        });

        expect(config.autoImport.settings.enabled).toBe(true);
        expect(config.autoImport.defaultDatabasePath).toBe("photosphere-default");
        expect(config.autoImport.pauseBetweenRunsMs).toBe(5000);
        expect(config.autoImportCleanupEnabled).toBe(true);
        expect(config.autoImport.settings.sources).toEqual([
            {
                type: "device-album",
                albumId: "all",
            },
        ]);

        expect(config.sync.settings.enabled).toBe(false);
        expect(config.sync.pauseBetweenRunsMs).toBe(DEFAULT_SYNC_PAUSE_MS);
    });

    test("unknown keys are ignored rather than throwing", () => {
        const document = {
            theme: "dark",
            something_nobody_defined: 42,
            sync: {
                enabled: true,
                a_key_from_a_later_version: "hello",
            },
        } as IYamlConfigFile;

        const config = yamlToConfigFile(document);

        expect(config.theme).toBe("dark");
        expect(config.sync.settings.enabled).toBe(true);
    });

    test("a malformed section falls back to that section's defaults without discarding the sections that parsed", () => {
        const document = {
            theme: "light",
            sync: "not a section at all",
            auto_import: {
                enabled: true,
                default_database_path: "kept",
            },
            saved_searches: "not a list",
        } as any;

        const config = yamlToConfigFile(document);

        expect(config.theme).toBe("light");
        expect(config.autoImport.settings.enabled).toBe(true);
        expect(config.autoImport.defaultDatabasePath).toBe("kept");

        expect(config.sync.settings.enabled).toBe(false);
        expect(config.sync.settings.onlyOnWifi).toBe(true);
        expect(config.savedSearches).toBeUndefined();
    });

    test("a saved search of the wrong type is dropped and the rest of the list kept", () => {
        const config = yamlToConfigFile({ saved_searches: ["beach", 17, "dogs"] } as any);

        expect(config.savedSearches).toEqual(["beach", "dogs"]);
    });

    test("a theme the file invents is ignored", () => {
        const config = yamlToConfigFile({ theme: "neon" } as any);

        expect(config.theme).toBeUndefined();
    });

    test("a malformed source is dropped and the rest are kept", () => {
        const config = yamlToConfigFile({
            auto_import: {
                enabled: true,
                sources: [
                    {
                        type: "folder",
                        path: "/photos",
                        recurse: false,
                    },
                    {
                        type: "folder",
                    },
                    {
                        type: "device-album",
                        album_id: "all",
                    },
                ],
            },
        });

        expect(config.autoImport.settings.sources).toEqual([
            {
                type: "folder",
                path: "/photos",
                recurse: false,
            },
            {
                type: "device-album",
                albumId: "all",
            },
        ]);
    });

    test("a pause of zero falls back to the default", () => {
        const config = yamlToConfigFile({
            auto_import: { pause_between_runs_ms: 0 },
            sync: { pause_between_runs_ms: -1 },
        });

        expect(config.autoImport.pauseBetweenRunsMs).toBe(DEFAULT_AUTO_IMPORT_PAUSE_MS);
        expect(config.sync.pauseBetweenRunsMs).toBe(DEFAULT_SYNC_PAUSE_MS);
    });

    test("an empty database path reads as absent rather than as an empty string", () => {
        const config = yamlToConfigFile({
            auto_import: { default_database_path: "" },
            sync: { database_path: "" },
        });

        expect(config.autoImport.defaultDatabasePath).toBeUndefined();
        expect(config.sync.databasePath).toBeUndefined();
    });
});

//
// A configuration with every field set, used by the round-trip tests.
//
function fullConfig(): IConfigFile {
    return {
        theme: "dark",
        developerMode: true,
        autoImport: {
            settings: {
                enabled: true,
                sources: [
                    {
                        type: "folder",
                        path: "/home/user/Pictures",
                        recurse: true,
                    },
                    {
                        type: "device-album",
                        albumId: "all",
                    },
                ],
            },
            defaultDatabasePath: "/home/user/photos",
            pauseBetweenRunsMs: 12345,
        },
        autoImportCleanupEnabled: true,
        sync: {
            settings: {
                enabled: true,
                onlyOnWifi: false,
            },
            databasePath: "/home/user/photos",
            pauseBetweenRunsMs: 54321,
        },
        showFpsIndicator: true,
        savedSearches: ["beach", "2024 birthday"],
    };
}

describe("configFileToYaml", () => {

    test("every field round-trips through configFileToYaml then yamlToConfigFile unchanged", () => {
        const original = fullConfig();

        const roundTripped = yamlToConfigFile(configFileToYaml(original));

        expect(roundTripped).toEqual(original);
    });

    test("an absent optional field stays absent rather than being written as null", () => {
        const config = defaultConfigFile();

        const document = configFileToYaml(config);

        expect(document.theme).toBeUndefined();
        expect(document.developer_mode).toBeUndefined();
        expect(document.auto_import!.default_database_path).toBeUndefined();
        expect(document.auto_import!.cleanup_enabled).toBeUndefined();
        expect(document.sync!.database_path).toBeUndefined();

        expect(document.show_fps_indicator).toBeUndefined();
        expect(document.saved_searches).toBeUndefined();

        // The rendered document must not carry the absent keys at all.
        expect(buildConfigYaml(config)).not.toContain("null");
    });

    test("the searches the user saved are written at the top level", () => {
        const config = defaultConfigFile();
        config.savedSearches = ["beach", "dogs"];

        expect(configFileToYaml(config).saved_searches).toEqual(["beach", "dogs"]);
    });

    //
    // Which sections are written says which features have been set, and a reader uses that to tell
    // "nobody has chosen this" from "somebody switched it off". Writing every section every time
    // would tell a fresh install that both had already been decided.
    //
    test("writes only the sections it is asked for", () => {
        const config = fullConfig();

        const syncOnly = configFileToYaml(config, { autoImport: false, sync: true });
        expect(syncOnly.sync).toBeDefined();
        expect(syncOnly.auto_import).toBeUndefined();

        const autoImportOnly = configFileToYaml(config, { autoImport: true, sync: false });
        expect(autoImportOnly.auto_import).toBeDefined();
        expect(autoImportOnly.sync).toBeUndefined();

        const neither = configFileToYaml(config, { autoImport: false, sync: false });
        expect(neither.auto_import).toBeUndefined();
        expect(neither.sync).toBeUndefined();
        // The settings that belong to no feature are still written.
        expect(neither.theme).toBe("dark");
    });

    test("writes both sections when it is not told which to write", () => {
        const document = configFileToYaml(fullConfig());

        expect(document.auto_import).toBeDefined();
        expect(document.sync).toBeDefined();
    });

    test("an empty sources list round-trips as an empty list and not as absent", () => {
        const config = defaultConfigFile();
        config.autoImport.settings.sources = [];

        const document = configFileToYaml(config);

        expect(document.auto_import!.sources).toEqual([]);
        expect(yamlToConfigFile(document).autoImport.settings.sources).toEqual([]);
    });

    test("the emitted document puts auto-import keys under auto_import and sync keys under sync", () => {
        const document = configFileToYaml(fullConfig());

        expect(Object.keys(document.auto_import!).sort()).toEqual([
            "cleanup_enabled",
            "default_database_path",
            "enabled",
            "pause_between_runs_ms",
            "sources",
        ]);
        expect(Object.keys(document.sync!).sort()).toEqual([
            "database_path",
            "enabled",
            "only_on_wifi",
            "pause_between_runs_ms",
        ]);

        // Nothing that belongs in a section may also appear at the top level.
        expect((document as any).enabled).toBeUndefined();
        expect((document as any).only_on_wifi).toBeUndefined();
        expect((document as any).sources).toBeUndefined();
    });

    test("a folder source writes no album id and a device album source writes no path", () => {
        const document = configFileToYaml(fullConfig());

        expect(document.auto_import!.sources![0]).toEqual({
            type: "folder",
            path: "/home/user/Pictures",
            recurse: true,
        });
        expect(document.auto_import!.sources![1]).toEqual({
            type: "device-album",
            album_id: "all",
        });
    });
});

//
// Which sections a document carried, as distinct from the configuration, which fills every section
// from the defaults. A caller has to tell "nobody has chosen this" from "somebody switched it off",
// and the settings alone cannot say which, because both read as switched off.
//
describe("sectionsPresent", () => {

    test("an absent document carries no sections", () => {
        expect(sectionsPresent(undefined)).toEqual({
            autoImport: false,
            sync: false,
        });
    });

    test("reports each section on its own", () => {
        expect(sectionsPresent({ auto_import: { enabled: true } })).toEqual({
            autoImport: true,
            sync: false,
        });
        expect(sectionsPresent({ sync: { enabled: true } })).toEqual({
            autoImport: false,
            sync: true,
        });
        expect(sectionsPresent({ auto_import: {}, sync: {} })).toEqual({
            autoImport: true,
            sync: true,
        });
    });

    test("a document holding only settings that belong to no feature carries neither section", () => {
        expect(sectionsPresent({ theme: "dark" })).toEqual({
            autoImport: false,
            sync: false,
        });
    });

    test("a section that is not an object does not count as present", () => {
        // A hand-edited file can put a string or a list where a section belongs. Counting that as
        // "these settings have been chosen" would leave a fresh install unseeded on the strength of
        // a line that says nothing.
        expect(sectionsPresent({ sync: "off", auto_import: [1, 2] } as any)).toEqual({
            autoImport: false,
            sync: false,
        });
    });
});

describe("buildConfigYaml and parseConfigYaml", () => {

    test("buildConfigYaml produces a document yamlToConfigFile parses back to the input", () => {
        const original = fullConfig();

        const text = buildConfigYaml(original);

        expect(parseConfigYaml(text)).toEqual(original);
    });

    test("the rendered text nests the sections the way the documentation describes", () => {
        const text = buildConfigYaml(fullConfig());
        const document = yaml.load(text) as IYamlConfigFile;

        expect(document.auto_import!.enabled).toBe(true);
        expect(document.sync!.only_on_wifi).toBe(false);
        expect(document.saved_searches).toEqual(["beach", "2024 birthday"]);
        expect(document.theme).toBe("dark");
    });

    test("text that will not parse as YAML comes back as the defaults rather than throwing", () => {
        const config = parseConfigYaml("sync:\n  enabled: true\n   bad indentation: [");

        expect(config).toEqual(defaultConfigFile());
    });

    test("an empty document reads as the defaults", () => {
        expect(parseConfigYaml("")).toEqual(defaultConfigFile());
    });
});
