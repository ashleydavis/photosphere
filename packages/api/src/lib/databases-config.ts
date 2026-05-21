import * as os from "os";
import * as path from "path";
import { readJson, readToml, writeToml, pathExists, remove } from "node-utils";
//
// A database entry stored in databases.toml.
// The name field is the unique (case-insensitive) identifier for each entry.
//
export interface IDatabaseEntry {
    // Human-readable display name.
    name: string;

    // Optional description of this database.
    description: string;

    // Absolute filesystem path (or S3 path) to the database directory.
    path: string;

    // Optional origin string read from .db/config.json; refreshed each time the database is opened.
    origin?: string;

    // Vault secret name for S3 credentials.
    s3Key?: string;

    // Vault secret name for the encryption key pair.
    encryptionKey?: string;

    // Vault secret name for the geocoding API key.
    geocodingKey?: string;
}

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
// TOML on-disk shape for a single database entry (snake_case keys).
//
interface ITomlDatabaseEntry {
    // Human-readable display name.
    name: string;

    // Optional description of this database.
    description: string;

    // Absolute filesystem path (or S3 path) to the database directory.
    path: string;

    // Optional origin string.
    origin?: string;

    // Vault secret name for S3 credentials.
    s3_key?: string;

    // Vault secret name for the encryption key pair.
    encryption_key?: string;

    // Vault secret name for the geocoding API key.
    geocoding_key?: string;
}

//
// TOML on-disk shape for the databases config file (snake_case keys).
//
interface ITomlDatabasesConfig {
    // Array of database entries.
    databases?: ITomlDatabaseEntry[];

    // Recently opened database names.
    recent_database_names?: string[];

    // Legacy field — recently opened database paths. Migrated on load.
    recent_database_paths?: string[];
}

const CONFIG_DIR = process.env.PHOTOSPHERE_CONFIG_DIR || path.join(os.homedir(), ".config", "photosphere");
const DATABASES_FILE = path.join(CONFIG_DIR, "databases.toml");
const OLD_DATABASES_FILE = path.join(CONFIG_DIR, "databases.json");

//
// Converts a TOML-shaped database entry to the TypeScript IDatabaseEntry type.
//
function tomlEntryToDatabaseEntry(tomlEntry: ITomlDatabaseEntry): IDatabaseEntry {
    const entry: IDatabaseEntry = {
        name: tomlEntry.name,
        description: tomlEntry.description,
        path: tomlEntry.path,
    };
    if (tomlEntry.origin !== undefined) {
        entry.origin = tomlEntry.origin;
    }
    if (tomlEntry.s3_key !== undefined) {
        entry.s3Key = tomlEntry.s3_key;
    }
    if (tomlEntry.encryption_key !== undefined) {
        entry.encryptionKey = tomlEntry.encryption_key;
    }
    if (tomlEntry.geocoding_key !== undefined) {
        entry.geocodingKey = tomlEntry.geocoding_key;
    }
    return entry;
}

//
// Converts a TypeScript IDatabaseEntry to the TOML on-disk shape.
//
function databaseEntryToToml(entry: IDatabaseEntry): ITomlDatabaseEntry {
    const tomlEntry: ITomlDatabaseEntry = {
        name: entry.name,
        description: entry.description,
        path: entry.path,
    };
    if (entry.origin !== undefined) {
        tomlEntry.origin = entry.origin;
    }
    if (entry.s3Key !== undefined) {
        tomlEntry.s3_key = entry.s3Key;
    }
    if (entry.encryptionKey !== undefined) {
        tomlEntry.encryption_key = entry.encryptionKey;
    }
    if (entry.geocodingKey !== undefined) {
        tomlEntry.geocoding_key = entry.geocodingKey;
    }
    return tomlEntry;
}

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
// If the TOML file does not exist but an old JSON file does, migrates automatically.
// If the loaded TOML still uses the legacy `recent_database_paths` field, converts it
// to `recent_database_names` (resolving each path to its current entry's name; dropping
// paths that no longer match any entry) and rewrites the file.
// Returns a default config with an empty list if neither file exists.
//
export async function loadDatabasesConfig(): Promise<IDatabasesConfig> {
    if (!await pathExists(DATABASES_FILE)) {
        if (await pathExists(OLD_DATABASES_FILE)) {
            const jsonConfig = await readJson<{ databases?: IDatabaseEntry[]; recentDatabasePaths?: string[]; recentDatabaseNames?: string[] }>(OLD_DATABASES_FILE);
            const databases = Array.isArray(jsonConfig.databases) ? jsonConfig.databases : [];
            let recentDatabaseNames: string[];
            if (Array.isArray(jsonConfig.recentDatabaseNames)) {
                recentDatabaseNames = jsonConfig.recentDatabaseNames;
            }
            else if (Array.isArray(jsonConfig.recentDatabasePaths)) {
                recentDatabaseNames = recentPathsToNames(jsonConfig.recentDatabasePaths, databases);
            }
            else {
                recentDatabaseNames = [];
            }
            const migrated: IDatabasesConfig = { databases, recentDatabaseNames };
            await saveDatabasesConfig(migrated);
            await remove(OLD_DATABASES_FILE);
            return migrated;
        }
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
