import * as path from "path";
import { getConfigDir, readToml, updateToml, pathExists } from "node-utils";
import { databaseEntryToToml, tomlEntryToDatabaseEntry, type IDatabaseEntry, type ITomlDatabasesConfig } from "./databases-config-format";

// Re-exported: this module has always been where the codebase imports the entry type from. The
// definition now lives with the file format, which mobile shares.
export type { IDatabaseEntry };
//
// Configuration for the databases list, stored in ~/.config/photosphere/databases.toml.
//
export interface IDatabasesConfig {
    //
    // Structured list of configured databases.
    //
    databases: IDatabaseEntry[];

    //
    // Ordered list of recently opened database names, most recent first, capped at
    // MAX_RECENT_DATABASES.
    //
    recentDatabaseNames: string[];

    //
    // Path of the database to reopen on the next launch; absent when none is open.
    //
    lastDatabase?: string;
}

//
// The file holding the list of databases, in the Photosphere data directory.
//
// getConfigDir works out where that is per platform: under the user's home directory on desktop and
// on the CLI, and the app's storage sandbox on a device, which has no home directory.
//
// Getting this wrong is not harmless. It previously always appended ".config/photosphere", so on a
// device the lookup resolved to a file that cannot exist, every credential lookup found an empty
// list, and S3 databases failed with "Region is missing" while working perfectly on desktop.
//
const DATABASES_FILE = path.join(getConfigDir(), "databases.toml");

//
// The path of that file, for the worker tasks that write it. They take the path as input because a
// phone keeps the same file somewhere else, so they cannot work it out for themselves.
//
export function getDatabasesConfigPath(): string {
    return DATABASES_FILE;
}

//
// How many recently opened databases are remembered. Named once so the list that is trimmed and the
// list that is read back cannot disagree about the number.
//
export const MAX_RECENT_DATABASES = 5;

//
// Converts a TOML-shaped config object to the TypeScript IDatabasesConfig type.
//
export function tomlToDatabasesConfig(toml: ITomlDatabasesConfig): IDatabasesConfig {
    const databases = Array.isArray(toml.databases)
        ? toml.databases.map(tomlEntryToDatabaseEntry)
        : [];
    const recentDatabaseNames = Array.isArray(toml.recent_database_names)
        ? toml.recent_database_names
        : [];
    const config: IDatabasesConfig = { databases, recentDatabaseNames };
    if (typeof toml.last_database === "string") {
        config.lastDatabase = toml.last_database;
    }
    return config;
}

//
// Converts the TypeScript IDatabasesConfig to the TOML on-disk shape.
//
export function databasesConfigToToml(config: IDatabasesConfig): ITomlDatabasesConfig {
    const toml: ITomlDatabasesConfig = {
        databases: config.databases.map(databaseEntryToToml),
        recent_database_names: config.recentDatabaseNames,
    };

    // Only written when there is one. An absent key is what "no database is open" looks like on
    // disk, so writing an empty string instead would reopen a database whose path is nothing.
    if (config.lastDatabase !== undefined) {
        toml.last_database = config.lastDatabase;
    }
    return toml;
}

//
// Returns true if the two names match case-insensitively.
//
export function namesMatch(left: string, right: string): boolean {
    return left.toLowerCase() === right.toLowerCase();
}

//
// Loads the databases configuration from disk.
// Returns a default config with an empty list if the file does not exist.
//
export async function loadDatabasesConfig(): Promise<IDatabasesConfig> {
    if (!await pathExists(DATABASES_FILE)) {
        return { databases: [], recentDatabaseNames: [] };
    }

    const toml = await readToml<ITomlDatabasesConfig>(DATABASES_FILE);
    return tomlToDatabasesConfig(toml);
}

//
// Changes the databases configuration on disk. Every edit in this module goes through here.
//
// The mutator is handed the file's CURRENT contents and returns the new ones. updateToml runs it
// under the update lock beside the file, checks the file has not moved before renaming, and re-runs
// the mutator against the new contents if it has. So two edits arriving together both survive: the
// second is applied on top of the first rather than overwriting it.
//
// This replaced a saveDatabasesConfig that took a whole config and wrote it. Every caller was
// load-then-save, so two overlapping edits meant the later write silently discarded the earlier
// one's change, with nothing to show for it. Several processes write this one file: the Electron
// main process, the REST API and MCP utility processes, and the worker pool.
//
// Windows is where that stopped being silent. It refuses to rename over a file another handle still
// holds, so the overlapping renames surfaced as "EPERM: operation not permitted, rename ...
// databases.toml", failing one to six of the thirty three desktop smoke tests per run. Taking turns
// fixes the visible failure on Windows and the invisible one everywhere else.
//
// A mutator that throws is left to throw. The lock is released on the way out, and the caller gets
// its error rather than a half-applied change.
//
export async function updateDatabasesConfig(mutate: (config: IDatabasesConfig) => IDatabasesConfig): Promise<void> {
    const emptyConfig: ITomlDatabasesConfig = { databases: [], recent_database_names: [] };
    await updateToml<ITomlDatabasesConfig>(DATABASES_FILE, emptyConfig, currentToml => {
        const updated = mutate(tomlToDatabasesConfig(currentToml));
        return databasesConfigToToml(updated);
    });
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
    await updateDatabasesConfig(config => {
        const existing = config.databases.find(dbEntry => namesMatch(dbEntry.name, entry.name));
        if (existing) {
            throw new Error(`A database named "${entry.name}" already exists.`);
        }
        return {
            ...config,
            databases: [...config.databases, entry],
        };
    });
}

//
// Updates the entry currently identified by `originalName` with the new fields in `entry`.
// If the new entry's name differs from `originalName`, the matching slot in
// `recentDatabaseNames` is rewritten to keep the recents list pointing at the same entry.
// Throws if the rename would collide with another existing entry, or if no entry with
// `originalName` is found.
//
export async function updateDatabaseEntry(originalName: string, entry: IDatabaseEntry): Promise<void> {
    await updateDatabasesConfig(config => {
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
        return {
            ...config,
            databases: updatedDatabases,
            recentDatabaseNames: renamed
                ? config.recentDatabaseNames.map(recentName => namesMatch(recentName, originalName) ? entry.name : recentName)
                : config.recentDatabaseNames,
        };
    });
}

//
// Removes a database entry by name (case-insensitive).
// Removes only the first matching entry from `databases` (defensive against legacy state
// where two entries share a name). Also removes the same name from `recentDatabaseNames`.
// No-op if no entry matches.
//
export async function removeDatabaseEntry(name: string): Promise<void> {
    await updateDatabasesConfig(config => {
        const matchIndex = config.databases.findIndex(dbEntry => namesMatch(dbEntry.name, name));
        // Recents are cleaned whether or not the entry is there, in case of stale state naming an
        // entry that has already gone.
        const recentDatabaseNames = config.recentDatabaseNames.filter(recentName => !namesMatch(recentName, name));
        if (matchIndex === -1) {
            return { ...config, recentDatabaseNames };
        }
        const updatedDatabases = config.databases.slice();
        updatedDatabases.splice(matchIndex, 1);
        return { ...config, databases: updatedDatabases, recentDatabaseNames };
    });
}

//
// Returns the most recently opened databases, ordered most-recent first, at most
// MAX_RECENT_DATABASES of them.
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
    await updateDatabasesConfig(config => ({
        ...config,
        recentDatabaseNames: config.recentDatabaseNames.filter(recentName => !namesMatch(recentName, name)),
    }));
}

//
// Moves the database entry matching the given name (case-insensitive) to the front of
// recentDatabaseNames, trimming the list to MAX_RECENT_DATABASES entries.
// No-op if no entry matches.
//
export async function markDatabaseOpened(name: string): Promise<void> {
    await updateDatabasesConfig(config => {
        const found = config.databases.find(dbEntry => namesMatch(dbEntry.name, name));
        if (!found) {
            return config;
        }
        return {
            ...config,
            recentDatabaseNames: [
                found.name,
                ...config.recentDatabaseNames.filter(recentName => !namesMatch(recentName, found.name)),
            ].slice(0, MAX_RECENT_DATABASES),
        };
    });
}

//
// Returns the path of the database to reopen on the next launch, or undefined when none is open.
//
export async function getLastDatabase(): Promise<string | undefined> {
    const config = await loadDatabasesConfig();
    return config.lastDatabase;
}

//
// Records the database to reopen on the next launch. undefined clears it, which is what closing a
// database does.
//
// Written through updateDatabasesConfig like every other edit here, so the databases and recents
// lists are carried through untouched rather than being rewritten from a copy read earlier.
//
export async function setLastDatabase(databasePath: string | undefined): Promise<void> {
    await updateDatabasesConfig(config => ({
        ...config,
        lastDatabase: databasePath,
    }));
}
