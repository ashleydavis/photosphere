import * as os from "os";
import * as path from "path";
import { readJson, writeJson, pathExists } from "./fs";

//
// Configuration for the desktop app stored in ~/.config/photosphere/desktop.json
//
export interface IDesktopConfig {
    //
    // List of recently opened databases (max 20).
    //
    recentDatabases?: string[];

    //
    // The last database that was opened.
    //
    lastDatabase?: string;

    //
    // The last folder that was opened in the file dialog.
    //
    lastFolder?: string;
}

const CONFIG_DIR = path.join(os.homedir(), ".config", "photosphere");
const CONFIG_FILE = path.join(CONFIG_DIR, "desktop.json");
const MAX_RECENT_DATABASES = 20;

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
        return {
            recentDatabases: [],
        };
    }

    try {
        const config = await readJson<IDesktopConfig>(CONFIG_FILE);
        // Ensure recentDatabases is an array
        if (!Array.isArray(config.recentDatabases)) {
            config.recentDatabases = [];
        }
        // Limit to max size
        if (config.recentDatabases.length > MAX_RECENT_DATABASES) {
            config.recentDatabases = config.recentDatabases.slice(0, MAX_RECENT_DATABASES);
        }
        return config;
    }
    catch (error: any) {
        console.error("Failed to load desktop config:", error);
        return {
            recentDatabases: [],
        };
    }
}

//
// Saves the desktop configuration to disk.
//
export async function saveDesktopConfig(config: IDesktopConfig): Promise<void> {
    // Ensure recentDatabases is an array
    if (!Array.isArray(config.recentDatabases)) {
        config.recentDatabases = [];
    }
    // Limit to max size
    if (config.recentDatabases.length > MAX_RECENT_DATABASES) {
        config.recentDatabases = config.recentDatabases.slice(0, MAX_RECENT_DATABASES);
    }
    
    await writeJson(CONFIG_FILE, config, { spaces: 2 });
}

//
// Adds a database to the recent databases list and updates last database.
// Removes duplicates and limits to MAX_RECENT_DATABASES.
//
export async function addRecentDatabase(databasePath: string): Promise<void> {
    const config = await loadDesktopConfig();
    
    // Remove the database if it already exists in the list
    const filtered = (config.recentDatabases || []).filter(db => db !== databasePath);
    
    // Add to the beginning of the list
    config.recentDatabases = [databasePath, ...filtered].slice(0, MAX_RECENT_DATABASES);
    config.lastDatabase = databasePath;
    
    await saveDesktopConfig(config);
}

//
// Removes a database from the recent databases list.
//
export async function removeRecentDatabase(databasePath: string): Promise<void> {
    const config = await loadDesktopConfig();
    
    // Remove the database from the list
    config.recentDatabases = (config.recentDatabases || []).filter(db => db !== databasePath);
    
    // If it was the last database, clear that too
    if (config.lastDatabase === databasePath) {
        config.lastDatabase = undefined;
    }
    
    await saveDesktopConfig(config);
}

//
// Clears the last database that was opened.
//
export async function clearLastDatabase(): Promise<void> {
    const config = await loadDesktopConfig();
    config.lastDatabase = undefined;
    await saveDesktopConfig(config);
}

//
// Updates the last folder that was opened in the file dialog.
//
export async function updateLastFolder(folderPath: string): Promise<void> {
    const config = await loadDesktopConfig();
    config.lastFolder = folderPath;
    await saveDesktopConfig(config);
}

