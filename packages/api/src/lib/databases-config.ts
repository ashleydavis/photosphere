import * as os from "os";
import * as path from "path";
import { readJson, readToml, writeToml, pathExists, remove } from "node-utils";
import type { IDatabaseEntry } from "electron-defs";

//
// Configuration for the databases list, stored in ~/.config/photosphere/databases.toml.
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

    // Recently opened database paths.
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
//
function tomlToDatabasesConfig(toml: ITomlDatabasesConfig): IDatabasesConfig {
    const databases = Array.isArray(toml.databases)
        ? toml.databases.map(tomlEntryToDatabaseEntry)
        : [];
    const recentDatabasePaths = Array.isArray(toml.recent_database_paths)
        ? toml.recent_database_paths
        : [];
    return { databases, recentDatabasePaths };
}

//
// Converts the TypeScript IDatabasesConfig to the TOML on-disk shape.
//
function databasesConfigToToml(config: IDatabasesConfig): ITomlDatabasesConfig {
    return {
        databases: config.databases.map(databaseEntryToToml),
        recent_database_paths: config.recentDatabasePaths,
    };
}

//
// Loads the databases configuration from disk.
// If the TOML file does not exist but an old JSON file does, migrates automatically.
// Returns a default config with an empty list if neither file exists.
//
export async function loadDatabasesConfig(): Promise<IDatabasesConfig> {
    if (!await pathExists(DATABASES_FILE)) {
        if (await pathExists(OLD_DATABASES_FILE)) {
            const jsonConfig = await readJson<{ databases?: IDatabaseEntry[]; recentDatabasePaths?: string[] }>(OLD_DATABASES_FILE);
            const migrated: IDatabasesConfig = {
                databases: Array.isArray(jsonConfig.databases) ? jsonConfig.databases : [],
                recentDatabasePaths: Array.isArray(jsonConfig.recentDatabasePaths) ? jsonConfig.recentDatabasePaths : [],
            };
            await saveDatabasesConfig(migrated);
            await remove(OLD_DATABASES_FILE);
            return migrated;
        }
        return { databases: [], recentDatabasePaths: [] };
    }

    const toml = await readToml<ITomlDatabasesConfig>(DATABASES_FILE);
    return tomlToDatabasesConfig(toml);
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
