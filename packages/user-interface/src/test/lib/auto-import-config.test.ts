import { DEFAULT_AUTO_IMPORT_SETTINGS, IAutoImportSettings } from "api";
import { IConfig } from "../../context/config-store-context";
import {
    AUTO_IMPORT_ENABLED_KEY,
    AUTO_IMPORT_SOURCES_KEY,
    DEFAULT_DATABASE_PATH_KEY,
    getDefaultDatabasePath,
    loadAutoImportSettings,
    saveAutoImportSettings,
    setDefaultDatabasePath,
} from "../../lib/auto-import-config";

//
// A config store held in a map, standing in for whatever each platform actually writes to.
//
function makeConfig(initial: Map<string, any>): IConfig {
    const values = new Map(initial);
    return {
        async get<T>(key: string): Promise<T | undefined> {
            return values.get(key) as T | undefined;
        },
        async set<T>(key: string, value: T): Promise<void> {
            values.set(key, value);
        },
        async add<T>(key: string, item: T): Promise<void> {
            const current = (values.get(key) as T[] | undefined) ?? [];
            values.set(key, [item, ...current]);
        },
        async remove<T>(key: string, item: T): Promise<void> {
            const current = (values.get(key) as T[] | undefined) ?? [];
            values.set(key, current.filter(existing => existing !== item));
        },
        async clear(key: string): Promise<void> {
            values.delete(key);
        },
    };
}

describe("auto-import settings in the config store", () => {

    test("an empty config gives the defaults", async () => {
        const settings = await loadAutoImportSettings(makeConfig(new Map()));

        expect(settings).toEqual(DEFAULT_AUTO_IMPORT_SETTINGS);
    });

    test("settings round-trip", async () => {
        const config = makeConfig(new Map());
        const settings: IAutoImportSettings = {
            ...DEFAULT_AUTO_IMPORT_SETTINGS,
            enabled: true,
            sources: [{ type: "folder", path: "/home/someone/Pictures", recurse: true }],
        };

        await saveAutoImportSettings(config, settings);

        expect(await loadAutoImportSettings(config)).toEqual(settings);
    });

    test("each setting is written under its own key", async () => {
        const config = makeConfig(new Map());

        await saveAutoImportSettings(config, {
            ...DEFAULT_AUTO_IMPORT_SETTINGS,
            enabled: true,
            sources: [{ type: "device-album", albumId: "camera" }],
        });

        expect(await config.get(AUTO_IMPORT_ENABLED_KEY)).toBe(true);
        expect(await config.get(AUTO_IMPORT_SOURCES_KEY)).toEqual([{ type: "device-album", albumId: "camera" }]);
    });

    test("a malformed stored source is dropped rather than crashing the load", async () => {
        const config = makeConfig(new Map<string, any>([
            [AUTO_IMPORT_ENABLED_KEY, true],
            [AUTO_IMPORT_SOURCES_KEY, [{ type: "folder" }, { type: "folder", path: "/photos", recurse: true }]],
        ]));

        const settings = await loadAutoImportSettings(config);

        expect(settings.sources).toEqual([{ type: "folder", path: "/photos", recurse: true }]);
    });

    test("a missing value falls back to its default", async () => {
        const config = makeConfig(new Map<string, any>([[AUTO_IMPORT_ENABLED_KEY, true]]));

        const settings = await loadAutoImportSettings(config);

        expect(settings.enabled).toBe(true);
    });
});

describe("the default database", () => {

    test("there is none to begin with", async () => {
        expect(await getDefaultDatabasePath(makeConfig(new Map()))).toBeUndefined();
    });

    test("an empty stored path counts as none", async () => {
        const config = makeConfig(new Map<string, any>([[DEFAULT_DATABASE_PATH_KEY, ""]]));
        expect(await getDefaultDatabasePath(config)).toBeUndefined();
    });

    test("a stored value that is not a path counts as none", async () => {
        const config = makeConfig(new Map<string, any>([[DEFAULT_DATABASE_PATH_KEY, 42]]));
        expect(await getDefaultDatabasePath(config)).toBeUndefined();
    });

    test("the path round-trips", async () => {
        const config = makeConfig(new Map());

        await setDefaultDatabasePath(config, "/home/someone/photosphere-default");

        expect(await getDefaultDatabasePath(config)).toBe("/home/someone/photosphere-default");
    });

    test("setting a new default replaces the old one", async () => {
        const config = makeConfig(new Map());

        await setDefaultDatabasePath(config, "/first");
        await setDefaultDatabasePath(config, "/second");

        expect(await getDefaultDatabasePath(config)).toBe("/second");
    });
});
