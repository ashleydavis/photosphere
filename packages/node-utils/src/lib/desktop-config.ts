import * as os from "os";
import * as path from "path";
import { readJson, writeJson, pathExists } from "./fs";

//
// Configuration for the desktop app stored in ~/.config/photosphere/desktop.json
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

const CONFIG_DIR = path.join(os.homedir(), ".config", "photosphere");
const CONFIG_FILE = path.join(CONFIG_DIR, "desktop.json");
const MAX_RECENT_SEARCHES = 10;

//
// Gets the path to the config file.
//
export function getConfigPath(): string {
    return CONFIG_FILE;
}

//
// Loads the desktop configuration from disk.
// Returns default config if file doesn't exist.
//
export async function loadDesktopConfig(): Promise<IDesktopConfig> {
    if (!await pathExists(CONFIG_FILE)) {
        return {};
    }

    const config = await readJson<IDesktopConfig>(CONFIG_FILE);
    return config;
}

//
// Saves the desktop configuration to disk.
//
export async function saveDesktopConfig(config: IDesktopConfig): Promise<void> {
    await writeJson(CONFIG_FILE, config, { spaces: 2 });
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
