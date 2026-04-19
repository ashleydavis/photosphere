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
    // Ordered list of recently opened database IDs (most recent first, max 5).
    //
    recentDatabaseIds: string[];
}

const CONFIG_DIR = path.join(os.homedir(), ".config", "photosphere");
const DATABASES_FILE = path.join(CONFIG_DIR, "databases.json");

//
// Loads the databases configuration from disk.
// Returns a default config with an empty list if the file does not exist.
//
export async function loadDatabasesConfig(): Promise<IDatabasesConfig> {
    if (!await pathExists(DATABASES_FILE)) {
        return { databases: [], recentDatabaseIds: [] };
    }

    const config = await readJson<IDatabasesConfig>(DATABASES_FILE);
    if (!Array.isArray(config.databases)) {
        config.databases = [];
    }
    if (!Array.isArray(config.recentDatabaseIds)) {
        config.recentDatabaseIds = [];
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
    if (!Array.isArray(config.recentDatabaseIds)) {
        config.recentDatabaseIds = [];
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
// Updates an existing database entry matched by id.
//
export async function updateDatabaseEntry(entry: IDatabaseEntry): Promise<void> {
    const config = await loadDatabasesConfig();
    config.databases = config.databases.map(existing => existing.id === entry.id ? entry : existing);
    await saveDatabasesConfig(config);
}

//
// Removes a database entry by id.
//
export async function removeDatabaseEntry(id: string): Promise<void> {
    const config = await loadDatabasesConfig();
    config.databases = config.databases.filter(existing => existing.id !== id);
    await saveDatabasesConfig(config);
}

//
// Returns the top-5 most recently opened databases, ordered most-recent first.
// IDs that no longer exist in the databases list are silently dropped.
//
export async function getRecentDatabases(): Promise<IDatabaseEntry[]> {
    const config = await loadDatabasesConfig();
    const result: IDatabaseEntry[] = [];
    for (const recentId of config.recentDatabaseIds) {
        const found = config.databases.find(dbEntry => dbEntry.id === recentId);
        if (found) {
            result.push(found);
        }
    }
    return result;
}

//
// Moves the database entry matching the given path to the front of recentDatabaseIds,
// trimming the list to a maximum of 5 entries, then saves.
//
export async function markDatabaseOpenedByPath(databasePath: string): Promise<void> {
    const config = await loadDatabasesConfig();
    const found = config.databases.find(dbEntry => dbEntry.path === databasePath);
    if (!found) {
        return;
    }
    config.recentDatabaseIds = [
        found.id,
        ...config.recentDatabaseIds.filter(recentId => recentId !== found.id),
    ].slice(0, 5);
    await saveDatabasesConfig(config);
}
