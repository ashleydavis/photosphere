import * as os from "os";
import * as path from "path";
import { readJson, readToml, writeToml, pathExists, remove } from "node-utils";

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
}

const CONFIG_DIR = path.join(os.homedir(), ".config", "photosphere");
const CONFIG_FILE = path.join(CONFIG_DIR, "desktop.toml");
const OLD_CONFIG_FILE = path.join(CONFIG_DIR, "desktop.json");
const MAX_RECENT_SEARCHES = 10;

//
// Converts a TOML-shaped desktop config to the TypeScript IDesktopConfig type.
//
function tomlToDesktopConfig(toml: ITomlDesktopConfig): IDesktopConfig {
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
    return config;
}

//
// Converts the TypeScript IDesktopConfig to the TOML on-disk shape.
//
function desktopConfigToToml(config: IDesktopConfig): ITomlDesktopConfig {
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
// If the TOML file does not exist but an old JSON file does, migrates automatically.
// Returns default config if neither file exists.
//
export async function loadDesktopConfig(): Promise<IDesktopConfig> {
    if (!await pathExists(CONFIG_FILE)) {
        if (await pathExists(OLD_CONFIG_FILE)) {
            const jsonConfig = await readJson<IDesktopConfig>(OLD_CONFIG_FILE);
            await saveDesktopConfig(jsonConfig);
            await remove(OLD_CONFIG_FILE);
            return jsonConfig;
        }
        return {};
    }

    const toml = await readToml<ITomlDesktopConfig>(CONFIG_FILE);
    return tomlToDesktopConfig(toml);
}

//
// Saves the desktop configuration to disk.
//
export async function saveDesktopConfig(config: IDesktopConfig): Promise<void> {
    await writeToml(CONFIG_FILE, desktopConfigToToml(config));
}

//
// Updates the last folder that was opened in the file dialog.
//
export async function updateLastFolder(folderPath: string): Promise<void> {
    const config = await loadDesktopConfig();
    config.lastFolder = folderPath;
    await saveDesktopConfig(config);
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
    const config = await loadDesktopConfig();
    config.theme = theme;
    await saveDesktopConfig(config);
}

//
// Updates the last folder used when downloading assets.
//
export async function updateLastDownloadFolder(folderPath: string): Promise<void> {
    const config = await loadDesktopConfig();
    config.lastDownloadFolder = folderPath;
    await saveDesktopConfig(config);
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
    const config = await loadDesktopConfig();
    const filtered = (config.recentSearches || []).filter(item => item !== searchText);
    config.recentSearches = [searchText, ...filtered].slice(0, MAX_RECENT_SEARCHES);
    await saveDesktopConfig(config);
}

//
// Removes a search from the recent searches list.
//
export async function removeRecentSearch(searchText: string): Promise<void> {
    const config = await loadDesktopConfig();
    config.recentSearches = (config.recentSearches || []).filter(item => item !== searchText);
    await saveDesktopConfig(config);
}
