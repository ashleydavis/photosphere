//
// The config store the shared UI reads and writes through, backed by config.yaml.
//
// The UI works in one flat namespace of keys: `IConfig` in user-interface offers get, set, add,
// remove and clear over a string key, and every platform provides the get/set pair underneath it.
// This is that pair for the platforms with a filesystem, reached by the Electron main process
// through its `get-config` and `set-config` IPC channels and by the dev server through its config
// routes. Mobile answers the same keys from three places instead, because its WebView cannot open a
// file: the automatic import and syncing keys go through worker tasks to the same config.yaml, and
// everything else is kept in the WebView's own storage.
//
// So the interface asks for "syncEnabled" and knows nothing about where that lives, and this module
// is the only thing that does. A key can belong to any section of the file: "theme" is top level,
// "syncEnabled" is in `sync`, "autoImportSources" is in `auto_import`, "lastFolder" is in `desktop`.
// That is what lets the file be organised by feature while the UI keeps one namespace.
//
// It maps the raw document rather than the normalised configuration on purpose. Every field is
// optional and absent means absent, because the interface applies its own defaults to a setting
// nobody has touched: sync-context starts with syncing on and only overrides that when the store
// returns a value. Handing it the file reader's defaults instead would silently switch syncing off
// on a fresh install.
//

import { readYaml, updateYaml } from "node-utils";
import { IAutoImportSource, normaliseAutoImportSource } from "api";
import { getConfigPath } from "./config-file";
import { ALLOWED_THEMES } from "./config-format";
import type {
    IConfigTheme,
    IYamlAutoImportSection,
    IYamlDesktopSection,
    IYamlConfigFile,
    IYamlSyncSection,
} from "./config-format";

//
// Every setting the interface can reach by key, flattened into one namespace.
//
export interface IAppConfig {
    //
    // The last folder that was opened in the file dialog.
    //
    lastFolder?: string;

    //
    // The theme preference: 'light', 'dark', or 'system'.
    //
    theme?: IConfigTheme;

    //
    // List of recently executed searches (max MAX_RECENT_SEARCHES).
    //
    recentSearches?: string[];

    //
    // The last folder used when downloading assets.
    //
    lastDownloadFolder?: string;

    //
    // Whether the FPS indicator overlay is shown in the UI. Defaults to false when unset.
    //
    showFpsIndicator?: boolean;

    //
    // Whether developer mode is enabled (reveals developer tools in the UI). Defaults to false when unset.
    //
    developerMode?: boolean;

    //
    // Whether the developer tools (native inspector) should be open. Reopened on startup when true. Defaults to false when unset.
    //
    devToolsOpen?: boolean;

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
// How many searches the recent list keeps.
//
export const MAX_RECENT_SEARCHES = 10;

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

    if (isSection(document!.desktop)) {
        const desktop = document!.desktop!;
        if (typeof desktop.last_folder === "string") {
            config.lastFolder = desktop.last_folder;
        }
        if (typeof desktop.last_download_folder === "string") {
            config.lastDownloadFolder = desktop.last_download_folder;
        }
        if (Array.isArray(desktop.recent_searches)) {
            config.recentSearches = desktop.recent_searches.filter(search => typeof search === "string");
        }
        if (typeof desktop.show_fps_indicator === "boolean") {
            config.showFpsIndicator = desktop.show_fps_indicator;
        }
        if (typeof desktop.dev_tools_open === "boolean") {
            config.devToolsOpen = desktop.dev_tools_open;
        }
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
function sourceToYaml(source: IAutoImportSource): Record<string, any> {
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
// Writes the flat view back into the document, leaving everything this view does not own where it is.
//
// The merge matters: the document also carries the background loops' pacing, the database the mobile
// sync pushes and the news state, and none of those appear in the flat view. Rebuilding the document
// from the flat view alone would drop them every time the desktop app remembered a folder.
//
export function appConfigToYaml(config: IAppConfig, document: IYamlConfigFile): IYamlConfigFile {
    const merged: IYamlConfigFile = isSection(document) ? { ...document } : {};

    if (config.theme !== undefined) {
        merged.theme = config.theme;
    }
    if (config.developerMode !== undefined) {
        merged.developer_mode = config.developerMode;
    }

    const desktop: IYamlDesktopSection = isSection(merged.desktop) ? { ...merged.desktop } : {};
    if (config.lastFolder !== undefined) {
        desktop.last_folder = config.lastFolder;
    }
    if (config.lastDownloadFolder !== undefined) {
        desktop.last_download_folder = config.lastDownloadFolder;
    }
    if (config.recentSearches !== undefined) {
        desktop.recent_searches = config.recentSearches;
    }
    if (config.showFpsIndicator !== undefined) {
        desktop.show_fps_indicator = config.showFpsIndicator;
    }
    if (config.devToolsOpen !== undefined) {
        desktop.dev_tools_open = config.devToolsOpen;
    }
    merged.desktop = desktop;

    const sync: IYamlSyncSection = isSection(merged.sync) ? { ...merged.sync } : {};
    if (config.syncEnabled !== undefined) {
        sync.enabled = config.syncEnabled;
    }
    if (config.syncOnlyOnWifi !== undefined) {
        sync.only_on_wifi = config.syncOnlyOnWifi;
    }
    merged.sync = sync;

    const autoImport: IYamlAutoImportSection = isSection(merged.auto_import) ? { ...merged.auto_import } : {};
    if (config.autoImportEnabled !== undefined) {
        autoImport.enabled = config.autoImportEnabled;
    }
    if (config.defaultDatabasePath !== undefined) {
        autoImport.default_database_path = config.defaultDatabasePath;
    }
    if (config.autoImportCleanupEnabled !== undefined) {
        autoImport.cleanup_enabled = config.autoImportCleanupEnabled;
    }
    if (config.autoImportSources !== undefined) {
        autoImport.sources = config.autoImportSources.map(sourceToYaml);
    }
    merged.auto_import = autoImport;

    return merged;
}

//
// Loads the whole store from disk.
// Returns an empty config when the file does not exist, so every setting falls to its own default.
//
export async function loadAppConfig(): Promise<IAppConfig> {
    const document = await readYaml<IYamlConfigFile>(getConfigPath());
    return yamlToAppConfig(document);
}

//
// Changes the store on disk. Every edit goes through here.
//
// The mutator is handed the file's CURRENT contents and changes them in place. updateYaml runs it
// under the update lock beside the file, checks the file has not moved before renaming, and re-runs
// the mutator against the new contents if it has, so two edits arriving together both survive.
//
// This is the only way to write the file. A saveDesktopConfig that took a whole config and wrote it
// used to sit beside this, and its callers were all load-then-save, so an edit made between their
// read and their write was silently discarded. Windows made the same overlap visible on the sibling
// databases.toml, where it refuses to rename over a file another handle still holds.
//
export async function updateAppConfig(mutator: (config: IAppConfig) => void): Promise<void> {
    await updateYaml<IYamlConfigFile>(getConfigPath(), {}, (document) => {
        const config = yamlToAppConfig(document);
        mutator(config);
        return appConfigToYaml(config, document);
    });
}

//
// The config keys that remember a folder chosen in a folder picker.
//
export type FolderConfigKey = 'lastFolder' | 'lastDownloadFolder';

//
// Every config key a folder picker is allowed to read from and write back to.
//
export const FOLDER_CONFIG_KEYS: FolderConfigKey[] = ['lastFolder', 'lastDownloadFolder'];

//
// Narrows a folder key to one the config actually holds, throwing when it is not one of them.
//
// The key arrives from the renderer as a plain string, so without this an unrecognised key would be
// written into the config under a name nothing ever reads, and the picker would silently forget the
// folder every time.
//
export function asFolderConfigKey(folderKey: string): FolderConfigKey {
    const found = FOLDER_CONFIG_KEYS.find(candidate => candidate === folderKey);
    if (found === undefined) {
        throw new Error(`Unknown folder config key "${folderKey}". Expected one of: ${FOLDER_CONFIG_KEYS.join(', ')}.`);
    }
    return found;
}

//
// Gets the folder remembered under a folder picker's config key, used as the dialog's starting
// directory. Returns undefined when no folder has been remembered under that key yet.
//
export async function getFolderPath(folderKey: string): Promise<string | undefined> {
    // Checked before the file is opened, so an unrecognised key is refused without a read.
    const key = asFolderConfigKey(folderKey);
    const config = await loadAppConfig();
    return config[key];
}

//
// Remembers the folder a user chose under a folder picker's config key.
//
// Only that one key is written, and it is written against the file's CURRENT contents. A folder
// picker stays open for as long as the user takes to choose, so a config read before the dialog
// opened is stale by the time it closes, and writing that whole config back would undo anything
// changed in the meantime.
//
export async function updateFolderPath(folderKey: string, folderPath: string): Promise<void> {
    const key = asFolderConfigKey(folderKey);
    await updateAppConfig(config => {
        config[key] = folderPath;
    });
}

//
// Updates the last folder that was opened in the file dialog.
//
export async function updateLastFolder(folderPath: string): Promise<void> {
    await updateAppConfig(config => {
        config.lastFolder = folderPath;
    });
}

//
// Gets the theme preference.
//
export async function getTheme(): Promise<IConfigTheme> {
    const config = await loadAppConfig();
    return config.theme || 'system';
}

//
// Sets the theme preference.
//
export async function setTheme(theme: IConfigTheme): Promise<void> {
    await updateAppConfig(config => {
        config.theme = theme;
    });
}

//
// Updates the last folder used when downloading assets.
//
export async function updateLastDownloadFolder(folderPath: string): Promise<void> {
    await updateAppConfig(config => {
        config.lastDownloadFolder = folderPath;
    });
}

//
// Gets the recent searches list.
//
export async function getRecentSearches(): Promise<string[]> {
    const config = await loadAppConfig();
    return config.recentSearches || [];
}

//
// Adds a search to the recent searches list, deduplicating and capping at MAX_RECENT_SEARCHES.
//
export async function addRecentSearch(searchText: string): Promise<void> {
    await updateAppConfig(config => {
        const filtered = (config.recentSearches || []).filter(item => item !== searchText);
        config.recentSearches = [searchText, ...filtered].slice(0, MAX_RECENT_SEARCHES);
    });
}

//
// Removes a search from the recent searches list.
//
export async function removeRecentSearch(searchText: string): Promise<void> {
    await updateAppConfig(config => {
        config.recentSearches = (config.recentSearches || []).filter(item => item !== searchText);
    });
}
