import type { IDatabaseEntry, IShowNotificationData } from "user-interface";
import type { INewsFeedItem } from "node-api/src/lib/state-format";

//
// Client-side persistence for the mobile app's configured-databases and recent-databases lists.
//
// These live in databases.toml, the same file and the same format desktop keeps in
// ~/.config/photosphere (see packages/node-api/src/lib/databases-config.ts), except that mobile's
// copy sits in the app's storage sandbox. The functions below mirror that module's operations and
// semantics one for one, so the two platforms agree on what the file means.
//
// The mobile WebView cannot read files, so the reads and writes are handed to an
// IDatabasesConfigFile, which the platform provider implements with the embedded worker's
// read-databases-config / write-databases-config tasks. Keeping that behind an interface is what
// makes this module unit-testable without a device.
//
// The settings the interface names are not here. What the user chose is in config.yaml and what the
// app remembered is in state.yaml, both reached through mobile-config-file.ts, which is the mobile
// half of the same store the CLI and the desktop app use.
//

//
// The most recently opened databases the config retains, matching desktop.
//
const MAX_RECENT_DATABASES = 5;

//
// The databases config as held in databases.toml. Mirrors IDatabasesConfig in
// packages/node-api/src/lib/databases-config.ts.
//
export interface IDatabasesConfig {
    // The configured databases.
    databases: IDatabaseEntry[];

    // Recently opened database names, most recent first.
    recentDatabaseNames: string[];

    // Path of the database to open again on the next start, or undefined when none should be.
    lastDatabase: string | undefined;
}

//
// Reads and writes databases.toml. Implemented by the platform provider over the embedded worker,
// and by an in-memory double in tests.
//
export interface IDatabasesConfigFile {
    // Reads the config, returning empty lists when the file does not exist.
    read(): Promise<IDatabasesConfig>;

    // Writes the config, replacing the file's contents.
    write(config: IDatabasesConfig): Promise<void>;
}

//
// Returns true if the two names match case-insensitively. Names are the identity of an entry, the
// same as on desktop.
//
function namesMatch(left: string, right: string): boolean {
    return left.toLowerCase() === right.toLowerCase();
}

//
// Tail of the chain that serialises the config file's read-modify-write operations.
//
// Every mutating operation below reads the whole config, changes one field and writes the whole
// config back, and the read and the write are separate async round-trips to the embedded worker.
// Without serialisation two operations issued back to back interleave: both read the same starting
// config, and the second write clobbers the field the first one changed. Seeding the databases list
// and then the recents list lost one of the two that way, which dropped every recent (a recent is a
// name that has to resolve against the configured list) and left the sidebar empty. Desktop never
// needed this because it writes the file synchronously, and neither did mobile while these lists
// lived in localStorage.
//
let configOperationChain: Promise<void> = Promise.resolve();

//
// Runs one read-modify-write against the config file with no other such operation in flight.
//
// The chain continues on both settle paths so that one failed operation does not wedge every later
// one. The caller still sees its own rejection: only the chain's copy of the outcome is discarded.
//
async function withConfigLock<OperationResult>(operation: () => Promise<OperationResult>): Promise<OperationResult> {
    const runAfterPrevious = configOperationChain.then(operation, operation);
    configOperationChain = runAfterPrevious.then(() => undefined, () => undefined);
    return runAfterPrevious;
}

//
// Returns the configured databases.
//
export async function getDatabases(configFile: IDatabasesConfigFile): Promise<IDatabaseEntry[]> {
    const config = await configFile.read();
    return config.databases;
}

//
// Adds (or replaces, by case-insensitive name) a database entry, returning the stored entry.
//
export async function addDatabase(configFile: IDatabasesConfigFile, entry: IDatabaseEntry): Promise<IDatabaseEntry> {
    return withConfigLock(async () => {
        const config = await configFile.read();
        const remaining = config.databases.filter(existing => !namesMatch(existing.name, entry.name));
        remaining.push(entry);
        await configFile.write({ ...config, databases: remaining });
        return entry;
    });
}

//
// Updates the entry matching originalName (case-insensitive) to the new entry. A rename carries the
// recents list with it, so a recently opened database stays in recents under its new name, matching
// updateDatabaseEntry on desktop.
//
export async function updateDatabase(configFile: IDatabasesConfigFile, originalName: string, entry: IDatabaseEntry): Promise<void> {
    return withConfigLock(async () => {
        const config = await configFile.read();
        const databases = config.databases.map(existing => namesMatch(existing.name, originalName) ? entry : existing);
        const recentDatabaseNames = namesMatch(entry.name, originalName)
            ? config.recentDatabaseNames
            : config.recentDatabaseNames.map(recentName => namesMatch(recentName, originalName) ? entry.name : recentName);
        await configFile.write({ ...config, databases, recentDatabaseNames });
    });
}

//
// Removes the entry with the given name (case-insensitive), and drops it from recents, matching
// removeDatabaseEntry on desktop.
//
export async function removeDatabase(configFile: IDatabasesConfigFile, name: string): Promise<void> {
    return withConfigLock(async () => {
        const config = await configFile.read();
        await configFile.write({
            ...config,
            databases: config.databases.filter(existing => !namesMatch(existing.name, name)),
            recentDatabaseNames: config.recentDatabaseNames.filter(recentName => !namesMatch(recentName, name)),
        });
    });
}

//
// Finds a database entry by name (case-insensitive).
//
export async function findDatabase(configFile: IDatabasesConfigFile, name: string): Promise<IDatabaseEntry | undefined> {
    const config = await configFile.read();
    return config.databases.find(existing => namesMatch(existing.name, name));
}

//
// Finds a database entry by its path.
//
export async function findDatabaseByPath(configFile: IDatabasesConfigFile, databasePath: string): Promise<IDatabaseEntry | undefined> {
    const config = await configFile.read();
    return config.databases.find(existing => existing.path === databasePath);
}

//
// Sets (or clears) the replication origin on the database entry with the given path.
//
export async function setDatabaseOrigin(configFile: IDatabasesConfigFile, databasePath: string, origin: string | undefined): Promise<void> {
    return withConfigLock(async () => {
        const config = await configFile.read();
        const databases = config.databases.map(existing =>
            existing.path === databasePath ? { ...existing, origin } : existing);
        await configFile.write({ ...config, databases });
    });
}

//
// Returns the recently-opened databases (most-recent first). Names that no longer resolve to a
// configured database are dropped, matching getRecentDatabases on desktop.
//
export async function getRecentDatabases(configFile: IDatabasesConfigFile): Promise<IDatabaseEntry[]> {
    const config = await configFile.read();
    const entries: IDatabaseEntry[] = [];
    for (const recentName of config.recentDatabaseNames) {
        const found = config.databases.find(existing => namesMatch(existing.name, recentName));
        if (found) {
            entries.push(found);
        }
    }
    return entries;
}

//
// Records a database as most-recently opened, moving it to the front and trimming the list, matching
// markDatabaseOpened on desktop. The entry is registered first when the config does not know it yet,
// because recents hold names and a name that resolves to nothing would be dropped on the next read.
//
export async function addRecentDatabase(configFile: IDatabasesConfigFile, entry: IDatabaseEntry): Promise<void> {
    return withConfigLock(async () => {
        const config = await configFile.read();
        const known = config.databases.find(existing => namesMatch(existing.name, entry.name));
        const databases = known ? config.databases : [...config.databases, entry];
        await configFile.write({
            ...config,
            databases,
            recentDatabaseNames: [
                entry.name,
                ...config.recentDatabaseNames.filter(recentName => !namesMatch(recentName, entry.name)),
            ].slice(0, MAX_RECENT_DATABASES),
        });
    });
}

//
// Removes a database from the recent list by name (case-insensitive), leaving the entry itself
// configured, matching removeRecentDatabaseName on desktop.
//
export async function removeRecentDatabase(configFile: IDatabasesConfigFile, name: string): Promise<void> {
    return withConfigLock(async () => {
        const config = await configFile.read();
        await configFile.write({
            ...config,
            recentDatabaseNames: config.recentDatabaseNames.filter(recentName => !namesMatch(recentName, name)),
        });
    });
}

//
// Returns the first news item in the feed that has not yet been shown, or undefined when none remain.
//
// Both the feed and the ids already shown come from the caller, because both are kept in the `news`
// section of state.yaml, the same place and the same format the CLI and the desktop app keep them in.
//
export function firstUnshownNews(feed: INewsFeedItem[], shownNewsIds: string[]): INewsFeedItem | undefined {
    const shown = new Set(shownNewsIds);
    return feed.find(item => !shown.has(item.id));
}

//
// Maps a news item to the show-notification payload shown as a toast (with the newsId so dismissal
// can mark it shown). Defaults: 'primary' colour, no auto-dismiss.
//
export function buildNewsNotification(item: INewsFeedItem): IShowNotificationData {
    return {
        message: item.message,
        color: item.color ?? "primary",
        duration: item.duration ?? 0,
        newsId: item.id,
    };
}

//
// Derives a display name from a database path (its final path segment), used for the recent list and
// the "Database opened" log line.
//
export function databaseBasename(databasePath: string): string {
    const segments = databasePath.split(/[\\/]/).filter(segment => segment.length > 0);
    return segments.length > 0 ? segments[segments.length - 1] : databasePath;
}

//
// The path of the database to open again next time the app starts, or undefined when none should be.
//
export async function getLastDatabase(configFile: IDatabasesConfigFile): Promise<string | undefined> {
    const config = await configFile.read();
    return config.lastDatabase;
}

//
// Records the database to open again next time the app starts. undefined clears it, which is what
// closing a database does.
//
// This is kept in databases.toml rather than in the WebView's local storage, which is where it used
// to be. Local storage is flushed to disk when the WebView gets round to it, and Android kills an
// app without waiting for that: a phone that stopped the app a second after a database was opened
// came back with nothing open, and the user was returned to an empty app holding no clue why. The
// file is written through the worker, which has finished writing when it says it has.
//
export async function setLastDatabase(configFile: IDatabasesConfigFile, lastDatabase: string | undefined): Promise<void> {
    return withConfigLock(async () => {
        const config = await configFile.read();
        await configFile.write({
            ...config,
            lastDatabase,
        });
    });
}
