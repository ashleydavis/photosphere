import * as path from "path";
import { getConfigDir, readToml, updateToml, pathExists } from "node-utils";
import { IAutoImportSource } from "api";

//
// Configuration for the desktop app stored in ~/.config/photosphere/desktop.toml
//
export interface IDesktopConfig {
    //
    // The last folder that was opened in the file dialog.
    //
    lastFolder?: string;

    //
    // The theme preference: 'light', 'dark', or 'system'.
    //
    theme?: 'light' | 'dark' | 'system';

    //
    // List of recently executed searches (max 10).
    //
    recentSearches?: string[];

    //
    // The last folder used when downloading assets.
    //
    lastDownloadFolder?: string;

    //
    // The path of the last database that was opened; absent when none.
    //
    lastDatabase?: string;

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
// TOML on-disk shape for the desktop config file (snake_case keys).
//
interface ITomlDesktopConfig {
    // The last folder that was opened in the file dialog.
    last_folder?: string;

    // The theme preference.
    theme?: 'light' | 'dark' | 'system';

    // List of recently executed searches.
    recent_searches?: string[];

    // The last folder used when downloading assets.
    last_download_folder?: string;

    // The path of the last database that was opened.
    last_database?: string;

    // Whether the FPS indicator overlay is shown in the UI.
    show_fps_indicator?: boolean;

    // Whether developer mode is enabled.
    developer_mode?: boolean;

    // Whether the developer tools should be open, reopened on startup.
    dev_tools_open?: boolean;

    // Whether automatic syncing is enabled.
    sync_enabled?: boolean;

    // Whether automatic syncing is restricted to Wi-Fi.
    sync_only_on_wifi?: boolean;

    // Whether automatic photo import is switched on.
    auto_import_enabled?: boolean;

    // The path of the database automatic import writes to.
    default_database_path?: string;

    // The places automatic import watches, written as an array of TOML tables.
    auto_import_sources?: IAutoImportSource[];

    // Whether the source file is deleted once the photo is confirmed in the database.
    auto_import_cleanup_enabled?: boolean;
}

const CONFIG_FILE = path.join(getConfigDir(), "desktop.toml");
export const MAX_RECENT_SEARCHES = 10;

//
// Converts a TOML-shaped desktop config to the TypeScript IDesktopConfig type.
//
export function tomlToDesktopConfig(toml: ITomlDesktopConfig): IDesktopConfig {
    const config: IDesktopConfig = {};
    if (toml.last_folder !== undefined) {
        config.lastFolder = toml.last_folder;
    }
    if (toml.theme !== undefined) {
        config.theme = toml.theme;
    }
    if (toml.recent_searches !== undefined) {
        config.recentSearches = toml.recent_searches;
    }
    if (toml.last_download_folder !== undefined) {
        config.lastDownloadFolder = toml.last_download_folder;
    }
    if (toml.last_database !== undefined) {
        config.lastDatabase = toml.last_database;
    }
    if (toml.show_fps_indicator !== undefined) {
        config.showFpsIndicator = toml.show_fps_indicator;
    }
    if (toml.developer_mode !== undefined) {
        config.developerMode = toml.developer_mode;
    }
    if (toml.dev_tools_open !== undefined) {
        config.devToolsOpen = toml.dev_tools_open;
    }
    if (toml.sync_enabled !== undefined) {
        config.syncEnabled = toml.sync_enabled;
    }
    if (toml.sync_only_on_wifi !== undefined) {
        config.syncOnlyOnWifi = toml.sync_only_on_wifi;
    }
    if (toml.auto_import_enabled !== undefined) {
        config.autoImportEnabled = toml.auto_import_enabled;
    }
    if (toml.default_database_path !== undefined) {
        config.defaultDatabasePath = toml.default_database_path;
    }
    if (toml.auto_import_sources !== undefined) {
        config.autoImportSources = toml.auto_import_sources;
    }
    if (toml.auto_import_cleanup_enabled !== undefined) {
        config.autoImportCleanupEnabled = toml.auto_import_cleanup_enabled;
    }
    return config;
}

//
// Converts the TypeScript IDesktopConfig to the TOML on-disk shape.
//
export function desktopConfigToToml(config: IDesktopConfig): ITomlDesktopConfig {
    const toml: ITomlDesktopConfig = {};
    if (config.lastFolder !== undefined) {
        toml.last_folder = config.lastFolder;
    }
    if (config.theme !== undefined) {
        toml.theme = config.theme;
    }
    if (config.recentSearches !== undefined) {
        toml.recent_searches = config.recentSearches;
    }
    if (config.lastDownloadFolder !== undefined) {
        toml.last_download_folder = config.lastDownloadFolder;
    }
    if (config.lastDatabase !== undefined) {
        toml.last_database = config.lastDatabase;
    }
    if (config.showFpsIndicator !== undefined) {
        toml.show_fps_indicator = config.showFpsIndicator;
    }
    if (config.developerMode !== undefined) {
        toml.developer_mode = config.developerMode;
    }
    if (config.devToolsOpen !== undefined) {
        toml.dev_tools_open = config.devToolsOpen;
    }
    if (config.syncEnabled !== undefined) {
        toml.sync_enabled = config.syncEnabled;
    }
    if (config.syncOnlyOnWifi !== undefined) {
        toml.sync_only_on_wifi = config.syncOnlyOnWifi;
    }
    if (config.autoImportEnabled !== undefined) {
        toml.auto_import_enabled = config.autoImportEnabled;
    }
    if (config.defaultDatabasePath !== undefined) {
        toml.default_database_path = config.defaultDatabasePath;
    }
    if (config.autoImportSources !== undefined) {
        toml.auto_import_sources = config.autoImportSources;
    }
    if (config.autoImportCleanupEnabled !== undefined) {
        toml.auto_import_cleanup_enabled = config.autoImportCleanupEnabled;
    }
    return toml;
}

//
// Gets the path to the config file.
//
export function getConfigPath(): string {
    return CONFIG_FILE;
}

//
// Loads the desktop configuration from disk.
// Returns a default config if the file does not exist.
//
export async function loadDesktopConfig(): Promise<IDesktopConfig> {
    if (!await pathExists(CONFIG_FILE)) {
        return {};
    }

    const toml = await readToml<ITomlDesktopConfig>(CONFIG_FILE);
    return tomlToDesktopConfig(toml);
}

//
// Changes the desktop configuration on disk. Every edit goes through here.
//
// The mutator is handed the file's CURRENT contents and changes them in place. updateToml runs it
// under the update lock beside the file, checks the file has not moved before renaming, and re-runs
// the mutator against the new contents if it has, so two edits arriving together both survive.
//
// This is the only way to write the file. A saveDesktopConfig that took a whole config and wrote it
// used to sit beside this, and its callers were all load-then-save, so an edit made between their
// read and their write was silently discarded. Windows made the same overlap visible on the sibling
// databases.toml, where it refuses to rename over a file another handle still holds.
//
export async function updateDesktopConfig(mutator: (config: IDesktopConfig) => void): Promise<void> {
    await updateToml<ITomlDesktopConfig>(CONFIG_FILE, {}, (toml) => {
        const config = tomlToDesktopConfig(toml);
        mutator(config);
        return desktopConfigToToml(config);
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
    const config = await loadDesktopConfig();
    return config[asFolderConfigKey(folderKey)];
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
    await updateDesktopConfig(config => {
        config[key] = folderPath;
    });
}

//
// Updates the last folder that was opened in the file dialog.
//
export async function updateLastFolder(folderPath: string): Promise<void> {
    await updateDesktopConfig(config => {
        config.lastFolder = folderPath;
    });
}

//
// Gets the theme preference.
//
export async function getTheme(): Promise<'light' | 'dark' | 'system'> {
    const config = await loadDesktopConfig();
    return config.theme || 'system';
}

//
// Sets the theme preference.
//
export async function setTheme(theme: 'light' | 'dark' | 'system'): Promise<void> {
    await updateDesktopConfig(config => {
        config.theme = theme;
    });
}

//
// Updates the last folder used when downloading assets.
//
export async function updateLastDownloadFolder(folderPath: string): Promise<void> {
    await updateDesktopConfig(config => {
        config.lastDownloadFolder = folderPath;
    });
}

//
// Gets the recent searches list.
//
export async function getRecentSearches(): Promise<string[]> {
    const config = await loadDesktopConfig();
    return config.recentSearches || [];
}

//
// Adds a search to the recent searches list, deduplicating and capping at MAX_RECENT_SEARCHES.
//
export async function addRecentSearch(searchText: string): Promise<void> {
    await updateDesktopConfig(config => {
        const filtered = (config.recentSearches || []).filter(item => item !== searchText);
        config.recentSearches = [searchText, ...filtered].slice(0, MAX_RECENT_SEARCHES);
    });
}

//
// Removes a search from the recent searches list.
//
export async function removeRecentSearch(searchText: string): Promise<void> {
    await updateDesktopConfig(config => {
        config.recentSearches = (config.recentSearches || []).filter(item => item !== searchText);
    });
}

