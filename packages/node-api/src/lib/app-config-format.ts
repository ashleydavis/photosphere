//
// The flat key/value view of config.yaml that the interface works in.
//
// `IConfig` in user-interface offers get, set, add, remove and clear over a plain string key, and
// every platform provides the get/set pair underneath it. This module is the one definition of what
// the config keys mean: which section of the document each one sits in, and what it is called on disk.
// The state keys are the same idea over state.yaml, in app-state-format.ts. Nothing decides between
// the two: the interface has a context per store and the caller asks the one it means.
//
// It touches no filesystem, which is what lets it be bundled into the mobile worker. The functions
// that open the file are in app-config.ts, which re-exports everything here so a caller that wants
// both does not have to know they are two modules.
//
// It maps the raw document rather than the normalised configuration on purpose. Every field is
// optional and absent means absent, because the interface applies its own defaults to a setting
// nobody has touched: sync-context starts with syncing on and only overrides that when the store
// returns a value. Handing it the file reader's defaults instead would silently switch syncing off on
// a fresh install. That is why this view exists beside IConfigFile rather than being folded into it.
//

import { IAutoImportSource, normaliseAutoImportSource } from "api";
import { ALLOWED_THEMES } from "./config-format";
import type {
    IConfigTheme,
    IYamlAutoImportSection,
    IYamlAutoImportSource,
    IYamlConfigFile,
    IYamlSyncSection,
} from "./config-format";

//
// Every setting the user chooses, flattened into one namespace.
//
export interface IAppConfig {
    //
    // The theme preference: 'light', 'dark', or 'system'.
    //
    theme?: IConfigTheme;

    //
    // Whether developer mode is enabled (reveals developer tools in the UI). Defaults to false when unset.
    //
    developerMode?: boolean;

    //
    // Whether the FPS indicator overlay is shown in the UI. Defaults to false when unset.
    //
    showFpsIndicator?: boolean;

    //
    // The searches the user has deliberately saved from the sidebar.
    //
    savedSearches?: string[];

    //
    // Whether automatic syncing is enabled. Defaults to true when unset (applied by the UI).
    //
    syncEnabled?: boolean;

    //
    // Whether automatic syncing is restricted to Wi-Fi. Defaults to true when unset (applied by the UI).
    //
    syncOnlyOnWifi?: boolean;

    //
    // Whether automatic photo import is switched on. Defaults to false when unset.
    //
    autoImportEnabled?: boolean;

    //
    // The path of the database automatic import writes to; absent until one has been made the default.
    //
    defaultDatabasePath?: string;

    //
    // The places automatic import watches. On desktop these are folders; the type is the shared
    // union so the same settings mean the same thing on every platform.
    //
    autoImportSources?: IAutoImportSource[];

    //
    // Whether the source file is deleted once the photo is confirmed in the database. Defaults to
    // false when unset.
    //
    autoImportCleanupEnabled?: boolean;
}

//
// A value one of the flat config keys can hold.
//
export type IAppConfigValue = boolean | number | string | string[] | IAutoImportSource[];

//
// Reads one flat config key. undefined when nothing has been stored under it.
//
// Every key config.yaml holds is declared as a field of IAppConfig, so unlike the state view there is
// no catch-all here: a key that is not a config key never reaches this module, because the routing
// sends it to state.yaml instead.
//
export function getAppConfigValue(config: IAppConfig, key: string): IAppConfigValue | undefined {
    return (config as Record<string, IAppConfigValue | undefined>)[key];
}

//
// Writes one flat config key. undefined removes it, which is what IConfig.clear means.
//
export function setAppConfigValue(config: IAppConfig, key: string, value: IAppConfigValue | undefined): void {
    const fields = config as Record<string, IAppConfigValue | undefined>;
    if (value === undefined) {
        delete fields[key];
        return;
    }
    fields[key] = value;
}

//
// Every config key that has a value, under the name the interface uses for it.
//
// The whole config store in one object, for a caller that wants to read settings by name without
// having to know which section each one sits in.
//
export function appConfigSettings(config: IAppConfig): Record<string, IAppConfigValue> {
    const settings: Record<string, IAppConfigValue> = {};

    for (const key of Object.keys(config)) {
        const value = (config as Record<string, IAppConfigValue | undefined>)[key];
        if (value !== undefined) {
            settings[key] = value;
        }
    }

    return settings;
}

//
// True when the value is an object we can read keys off, and not an array or null. A hand-edited
// file can put a string or a list where a section belongs, and reading keys off one of those gives
// undefined for everything, which would look like an empty section rather than a malformed one.
//
function isSection(value: any): boolean {
    return typeof value === "object" && value !== null && !Array.isArray(value);
}

//
// Turns the watched places in the document into settings, dropping any that are malformed.
//
// It goes through the shared normaliser rather than trusting the file, because this list reaches the
// import task and a source with no path would have it scanning nothing while looking like it worked.
//
function documentSources(section: IYamlAutoImportSection): IAutoImportSource[] | undefined {
    if (!Array.isArray(section.sources)) {
        return undefined;
    }

    const sources: IAutoImportSource[] = [];
    for (const rawSource of section.sources) {
        const source = normaliseAutoImportSource({
            type: rawSource?.type,
            path: rawSource?.path,
            recurse: rawSource?.recurse,
            albumId: rawSource?.album_id,
        });
        if (source !== undefined) {
            sources.push(source);
        }
    }
    return sources;
}

//
// Flattens the on-disk document into the key/value view the interface works in.
//
export function yamlToAppConfig(document: IYamlConfigFile | undefined): IAppConfig {
    const config: IAppConfig = {};
    if (!isSection(document)) {
        return config;
    }

    if (typeof document!.theme === "string" && ALLOWED_THEMES.includes(document!.theme)) {
        config.theme = document!.theme;
    }
    if (typeof document!.developer_mode === "boolean") {
        config.developerMode = document!.developer_mode;
    }
    if (typeof document!.show_fps_indicator === "boolean") {
        config.showFpsIndicator = document!.show_fps_indicator;
    }
    if (Array.isArray(document!.saved_searches)) {
        config.savedSearches = document!.saved_searches.filter((search: any) => typeof search === "string");
    }

    if (isSection(document!.sync)) {
        const sync = document!.sync!;
        if (typeof sync.enabled === "boolean") {
            config.syncEnabled = sync.enabled;
        }
        if (typeof sync.only_on_wifi === "boolean") {
            config.syncOnlyOnWifi = sync.only_on_wifi;
        }
    }

    if (isSection(document!.auto_import)) {
        const autoImport = document!.auto_import!;
        if (typeof autoImport.enabled === "boolean") {
            config.autoImportEnabled = autoImport.enabled;
        }
        if (typeof autoImport.default_database_path === "string") {
            config.defaultDatabasePath = autoImport.default_database_path;
        }
        if (typeof autoImport.cleanup_enabled === "boolean") {
            config.autoImportCleanupEnabled = autoImport.cleanup_enabled;
        }
        const sources = documentSources(autoImport);
        if (sources !== undefined) {
            config.autoImportSources = sources;
        }
    }

    return config;
}

//
// Converts one watched place to its on-disk contents, writing only the fields its kind uses.
//
function sourceToYaml(source: IAutoImportSource): IYamlAutoImportSource {
    if (source.type === "folder") {
        return {
            type: "folder",
            path: source.path,
            recurse: source.recurse,
        };
    }

    return {
        type: "device-album",
        album_id: source.albumId,
    };
}

//
// Writes one field into a section, or removes it from the section when it has been cleared.
//
// Removing matters because this view is built from the document: a field that is absent here was
// absent there, so writing "nothing" back has to mean the key goes, or IConfig.clear would report
// success and change nothing on disk. A value the reader refused (a theme naming a colour that does
// not exist) also arrives here as absent and is dropped on the next write, which costs the user that
// one line and no other setting in the file.
//
function writeField(section: Record<string, any>, key: string, value: any): void {
    if (value === undefined) {
        delete section[key];
        return;
    }
    section[key] = value;
}

//
// Writes a section into the document, or leaves the document without it when it holds nothing.
//
// An empty section is never written, because for both of these the file uses the section's presence to
// answer a question the settings themselves cannot: an empty `sync` section says syncing has been
// decided, and a fresh install told that keeps syncing switched off while its toggles say it is on.
// The desktop app used to stamp an empty one into the file the first time a theme was changed, which
// only went unnoticed because nothing on that platform reads the answer.
//
function writeSection(document: Record<string, any>, name: string, section: Record<string, any>): void {
    if (Object.keys(section).length > 0) {
        document[name] = section;
        return;
    }
    delete document[name];
}

//
// Writes the flat view back into the document, leaving everything this view does not own where it is.
//
// The merge matters: the document also carries the background loops' pacing and the database the
// mobile sync pushes, and neither appears in the flat view. Rebuilding the document from the flat view
// alone would drop them every time the desktop app remembered a theme.
//
export function appConfigToYaml(config: IAppConfig, document: IYamlConfigFile): IYamlConfigFile {
    const merged: IYamlConfigFile = isSection(document) ? { ...document } : {};

    writeField(merged, "theme", config.theme);
    writeField(merged, "developer_mode", config.developerMode);
    writeField(merged, "show_fps_indicator", config.showFpsIndicator);
    writeField(merged, "saved_searches", config.savedSearches);

    const sync: IYamlSyncSection = isSection(merged.sync) ? { ...merged.sync } : {};
    writeField(sync, "enabled", config.syncEnabled);
    writeField(sync, "only_on_wifi", config.syncOnlyOnWifi);
    writeSection(merged, "sync", sync);

    const autoImport: IYamlAutoImportSection = isSection(merged.auto_import) ? { ...merged.auto_import } : {};
    writeField(autoImport, "enabled", config.autoImportEnabled);
    writeField(autoImport, "default_database_path", config.defaultDatabasePath);
    writeField(autoImport, "cleanup_enabled", config.autoImportCleanupEnabled);
    writeField(autoImport, "sources", config.autoImportSources ? config.autoImportSources.map(sourceToYaml) : undefined);
    writeSection(merged, "auto_import", autoImport);

    return merged;
}
