import * as os from "os";
import * as path from "path";
import { readToml, writeToml, pathExists } from "node-utils";
import { databaseEntryToToml, tomlEntryToDatabaseEntry, type IDatabaseEntry, type ITomlDatabasesConfig } from "./databases-config-format";

// Re-exported: this module has always been where the codebase imports the entry type from. The
// definition now lives with the file format, which mobile shares.
export type { IDatabaseEntry };
//
// Configuration for the databases list, stored in ~/.config/photosphere/databases.toml.
//
interface IDatabasesConfig {
    //
    // Structured list of configured databases.
    //
    databases: IDatabaseEntry[];

    //
    // Ordered list of recently opened database names (most recent first, max 5).
    //
    recentDatabaseNames: string[];
}

//
// The directory holding databases.toml.
//
// Desktop and the CLI keep it under the user's home directory. A device has no home directory: the
// mobile `os` shim returns an empty string from homedir() precisely so derived paths stay inside the
// storage sandbox, and the app's database list sits at the root of that sandbox. Reading homedir()
// therefore tells this module which platform it is on without either side having to configure it.
//
// Getting this wrong is not harmless. It previously always appended ".config/photosphere", so on a
// device the lookup resolved to a file that cannot exist, every credential lookup found an empty
// list, and S3 databases failed with "Region is missing" while working perfectly on desktop.
//
const HOME_DIR = os.homedir();
const CONFIG_DIR = process.env.PHOTOSPHERE_CONFIG_DIR || (HOME_DIR ? path.join(HOME_DIR, ".config", "photosphere") : ".");
const DATABASES_FILE = path.join(CONFIG_DIR, "databases.toml");

//
// Converts a TOML-shaped config object to the TypeScript IDatabasesConfig type.
// Recognises only the new `recent_database_names` field; legacy `recent_database_paths`
// migration is handled separately in `loadDatabasesConfig`.
//
function tomlToDatabasesConfig(toml: ITomlDatabasesConfig): IDatabasesConfig {
    const databases = Array.isArray(toml.databases)
        ? toml.databases.map(tomlEntryToDatabaseEntry)
        : [];
    const recentDatabaseNames = Array.isArray(toml.recent_database_names)
        ? toml.recent_database_names
        : [];
    return { databases, recentDatabaseNames };
}

//
// Converts the TypeScript IDatabasesConfig to the TOML on-disk shape.
//
function databasesConfigToToml(config: IDatabasesConfig): ITomlDatabasesConfig {
    return {
        databases: config.databases.map(databaseEntryToToml),
        recent_database_names: config.recentDatabaseNames,
    };
}

//
// Returns true if the two names match case-insensitively.
//
function namesMatch(left: string, right: string): boolean {
    return left.toLowerCase() === right.toLowerCase();
}

//
// Loads the databases configuration from disk.
// If the loaded TOML still uses the legacy `recent_database_paths` field, converts it
// to `recent_database_names` (resolving each path to its current entry's name; dropping
// paths that no longer match any entry) and rewrites the file.
// Returns a default config with an empty list if the file does not exist.
//
export async function loadDatabasesConfig(): Promise<IDatabasesConfig> {
    if (!await pathExists(DATABASES_FILE)) {
        return { databases: [], recentDatabaseNames: [] };
    }

    const toml = await readToml<ITomlDatabasesConfig>(DATABASES_FILE);

    // Legacy migration: convert recent_database_paths to recent_database_names and rewrite the file once.
    if (!Array.isArray(toml.recent_database_names) && Array.isArray(toml.recent_database_paths)) {
        const databases = Array.isArray(toml.databases)
            ? toml.databases.map(tomlEntryToDatabaseEntry)
            : [];
        const migrated: IDatabasesConfig = {
            databases,
            recentDatabaseNames: recentPathsToNames(toml.recent_database_paths, databases),
        };
        await saveDatabasesConfig(migrated);
        return migrated;
    }

    return tomlToDatabasesConfig(toml);
}

//
// Resolves the legacy recent-paths array into the new recent-names array by looking up
// each path in the current databases list. Paths that don't match any entry are dropped.
//
function recentPathsToNames(recentPaths: string[], databases: IDatabaseEntry[]): string[] {
    const result: string[] = [];
    for (const recentPath of recentPaths) {
        const match = databases.find(dbEntry => dbEntry.path === recentPath);
        if (match) {
            result.push(match.name);
        }
    }
    return result;
}

//
// Saves the databases configuration to disk.
//
export async function saveDatabasesConfig(config: IDatabasesConfig): Promise<void> {
    if (!Array.isArray(config.databases)) {
        config.databases = [];
    }
    if (!Array.isArray(config.recentDatabaseNames)) {
        config.recentDatabaseNames = [];
    }
    await writeToml(DATABASES_FILE, databasesConfigToToml(config));
}

//
// Returns all configured database entries.
//
export async function getDatabases(): Promise<IDatabaseEntry[]> {
    const config = await loadDatabasesConfig();
    return config.databases;
}

//
// Finds a database entry by name using case-insensitive matching.
// Returns the first match if any. Returns undefined if no entry matches.
//
export async function findDatabase(name: string): Promise<IDatabaseEntry | undefined> {
    const config = await loadDatabasesConfig();
    return config.databases.find(dbEntry => namesMatch(dbEntry.name, name));
}

//
// Adds a new database entry to the list.
// Throws if an entry with the same name (case-insensitive) already exists; this acts as
// a storage-layer invariant in addition to any UX checks.
//
export async function addDatabaseEntry(entry: IDatabaseEntry): Promise<void> {
    const config = await loadDatabasesConfig();
    const existing = config.databases.find(dbEntry => namesMatch(dbEntry.name, entry.name));
    if (existing) {
        throw new Error(`A database named "${entry.name}" already exists.`);
    }
    config.databases = [...config.databases, entry];
    await saveDatabasesConfig(config);
}

//
// Updates the entry currently identified by `originalName` with the new fields in `entry`.
// If the new entry's name differs from `originalName`, the matching slot in
// `recentDatabaseNames` is rewritten to keep the recents list pointing at the same entry.
// Throws if the rename would collide with another existing entry, or if no entry with
// `originalName` is found.
//
export async function updateDatabaseEntry(originalName: string, entry: IDatabaseEntry): Promise<void> {
    const config = await loadDatabasesConfig();
    const matchIndex = config.databases.findIndex(dbEntry => namesMatch(dbEntry.name, originalName));
    if (matchIndex === -1) {
        throw new Error(`No database named "${originalName}" found.`);
    }
    const renamed = !namesMatch(entry.name, originalName);
    if (renamed) {
        const collision = config.databases.find((dbEntry, dbIndex) => dbIndex !== matchIndex && namesMatch(dbEntry.name, entry.name));
        if (collision) {
            throw new Error(`A database named "${entry.name}" already exists.`);
        }
    }
    const updatedDatabases = config.databases.slice();
    updatedDatabases[matchIndex] = entry;
    config.databases = updatedDatabases;
    if (renamed) {
        config.recentDatabaseNames = config.recentDatabaseNames.map(recentName => namesMatch(recentName, originalName) ? entry.name : recentName);
    }
    await saveDatabasesConfig(config);
}

//
// Removes a database entry by name (case-insensitive).
// Removes only the first matching entry from `databases` (defensive against legacy state
// where two entries share a name). Also removes the same name from `recentDatabaseNames`.
// No-op if no entry matches.
//
export async function removeDatabaseEntry(name: string): Promise<void> {
    const config = await loadDatabasesConfig();
    const matchIndex = config.databases.findIndex(dbEntry => namesMatch(dbEntry.name, name));
    if (matchIndex === -1) {
        // Still clean recents in case of stale state.
        const filteredRecents = config.recentDatabaseNames.filter(recentName => !namesMatch(recentName, name));
        if (filteredRecents.length !== config.recentDatabaseNames.length) {
            config.recentDatabaseNames = filteredRecents;
            await saveDatabasesConfig(config);
        }
        return;
    }
    const updatedDatabases = config.databases.slice();
    updatedDatabases.splice(matchIndex, 1);
    config.databases = updatedDatabases;
    config.recentDatabaseNames = config.recentDatabaseNames.filter(recentName => !namesMatch(recentName, name));
    await saveDatabasesConfig(config);
}

//
// Returns the top-5 most recently opened databases, ordered most-recent first.
// Names that no longer resolve to an entry in the databases list are silently dropped.
//
export async function getRecentDatabases(): Promise<IDatabaseEntry[]> {
    const config = await loadDatabasesConfig();
    const result: IDatabaseEntry[] = [];
    for (const recentName of config.recentDatabaseNames) {
        const found = config.databases.find(dbEntry => namesMatch(dbEntry.name, recentName));
        if (found) {
            result.push(found);
        }
    }
    return result;
}

//
// Removes the given name from recentDatabaseNames only. Leaves the matching entry
// in `databases` untouched. No-op if the name is not in the recent list.
//
export async function removeRecentDatabaseName(name: string): Promise<void> {
    const config = await loadDatabasesConfig();
    const filtered = config.recentDatabaseNames.filter(recentName => !namesMatch(recentName, name));
    if (filtered.length === config.recentDatabaseNames.length) {
        return;
    }
    config.recentDatabaseNames = filtered;
    await saveDatabasesConfig(config);
}

//
// Moves the database entry matching the given name (case-insensitive) to the front of
// recentDatabaseNames, trimming the list to a maximum of 5 entries, then saves.
// No-op if no entry matches.
//
export async function markDatabaseOpened(name: string): Promise<void> {
    const config = await loadDatabasesConfig();
    const found = config.databases.find(dbEntry => namesMatch(dbEntry.name, name));
    if (!found) {
        return;
    }
    config.recentDatabaseNames = [
        found.name,
        ...config.recentDatabaseNames.filter(recentName => !namesMatch(recentName, found.name)),
    ].slice(0, 5);
    await saveDatabasesConfig(config);
}
