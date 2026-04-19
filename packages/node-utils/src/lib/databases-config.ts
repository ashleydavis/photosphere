import * as os from "os";
import * as path from "path";
import { readJson, writeJson, pathExists } from "./fs";
import type { IDatabaseEntry } from "electron-defs";

//
// Configuration for the databases list, stored in ~/.config/photosphere/databases.json.
//
interface IDatabasesConfig {
    //
    // Structured list of configured databases.
    //
    databases: IDatabaseEntry[];

    //
    // Ordered list of recently opened database paths (most recent first, max 5).
    //
    recentDatabasePaths: string[];
}

const CONFIG_DIR = process.env.PHOTOSPHERE_CONFIG_DIR || path.join(os.homedir(), ".config", "photosphere");
const DATABASES_FILE = path.join(CONFIG_DIR, "databases.json");

//
// Loads the databases configuration from disk.
// Returns a default config with an empty list if the file does not exist.
//
export async function loadDatabasesConfig(): Promise<IDatabasesConfig> {
    if (!await pathExists(DATABASES_FILE)) {
        return { databases: [], recentDatabasePaths: [] };
    }

    const config = await readJson<IDatabasesConfig>(DATABASES_FILE);
    if (!Array.isArray(config.databases)) {
        config.databases = [];
    }
    if (!Array.isArray(config.recentDatabasePaths)) {
        config.recentDatabasePaths = [];
    }
    return config;
}

//
// Saves the databases configuration to disk.
//
export async function saveDatabasesConfig(config: IDatabasesConfig): Promise<void> {
    if (!Array.isArray(config.databases)) {
        config.databases = [];
    }
    if (!Array.isArray(config.recentDatabasePaths)) {
        config.recentDatabasePaths = [];
    }
    await writeJson(DATABASES_FILE, config, { spaces: 2 });
}

//
// Returns all configured database entries.
//
export async function getDatabases(): Promise<IDatabaseEntry[]> {
    const config = await loadDatabasesConfig();
    return config.databases;
}

//
// Adds a new database entry to the list.
//
export async function addDatabaseEntry(entry: IDatabaseEntry): Promise<void> {
    const config = await loadDatabasesConfig();
    config.databases = [...config.databases, entry];
    await saveDatabasesConfig(config);
}

//
// Updates an existing database entry matched by path.
//
export async function updateDatabaseEntry(entry: IDatabaseEntry): Promise<void> {
    const config = await loadDatabasesConfig();
    config.databases = config.databases.map(existing => existing.path === entry.path ? entry : existing);
    await saveDatabasesConfig(config);
}

//
// Removes a database entry by path.
//
export async function removeDatabaseEntry(databasePath: string): Promise<void> {
    const config = await loadDatabasesConfig();
    config.databases = config.databases.filter(existing => existing.path !== databasePath);
    await saveDatabasesConfig(config);
}

//
// Returns the top-5 most recently opened databases, ordered most-recent first.
// IDs that no longer exist in the databases list are silently dropped.
//
export async function getRecentDatabases(): Promise<IDatabaseEntry[]> {
    const config = await loadDatabasesConfig();
    const result: IDatabaseEntry[] = [];
    for (const recentPath of config.recentDatabasePaths) {
        const found = config.databases.find(dbEntry => dbEntry.path === recentPath);
        if (found) {
            result.push(found);
        }
    }
    return result;
}

//
// Moves the database entry matching the given path to the front of recentDatabasePaths,
// trimming the list to a maximum of 5 entries, then saves.
//
export async function markDatabaseOpenedByPath(databasePath: string): Promise<void> {
    const config = await loadDatabasesConfig();
    const found = config.databases.find(dbEntry => dbEntry.path === databasePath);
    if (!found) {
        return;
    }
    config.recentDatabasePaths = [
        found.path,
        ...config.recentDatabasePaths.filter(recentPath => recentPath !== found.path),
    ].slice(0, 5);
    await saveDatabasesConfig(config);
}
