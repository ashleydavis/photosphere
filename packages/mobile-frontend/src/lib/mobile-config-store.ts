import type { IDatabaseEntry, IShowNotificationData } from "user-interface";

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
// makes this module unit-testable without a device, the same reason the news and generic-config
// functions below take an IKeyValueStore.
//

//
// localStorage key an earlier build kept the secrets list under, values and all, in plaintext. Secrets
// now live one-per-item in the device keychain (see mobile-secure-store.ts) and nothing writes this key
// any more. It is retained solely so resetConfig and the startup purge can delete a plaintext copy left
// behind on a device that ran that earlier build.
//
export const LEGACY_PLAINTEXT_SECRETS_KEY = "photosphere.secrets";

//
// localStorage key for the available news items (seeded in tests; would be fetched in production).
//
export const NEWS_KEY = "photosphere.news";

//
// localStorage key for the set of already-shown news item ids.
//
export const SHOWN_NEWS_KEY = "photosphere.shownNews";

//
// The most recently opened databases the config retains, matching desktop.
//
const MAX_RECENT_DATABASES = 5;

//
// The minimal key/value interface the news and generic-config functions need (a subset of the Web
// Storage API). Abstracted so unit tests can supply an in-memory implementation.
//
export interface IKeyValueStore {
    // Returns the stored string for a key, or null when absent.
    getItem(key: string): string | null;

    // Stores a string for a key.
    setItem(key: string, value: string): void;

    // Removes a key.
    removeItem(key: string): void;
}

//
// The databases config as held in databases.toml. Mirrors IDatabasesConfig in
// packages/node-api/src/lib/databases-config.ts.
//
export interface IDatabasesConfig {
    // The configured databases.
    databases: IDatabaseEntry[];

    // Recently opened database names, most recent first.
    recentDatabaseNames: string[];
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
// Reads and parses a JSON array from the store, returning [] when missing or malformed.
//
function readArray<EntryT>(store: IKeyValueStore, key: string): EntryT[] {
    const raw = store.getItem(key);
    if (!raw) {
        return [];
    }
    try {
        const parsed = JSON.parse(raw);
        return Array.isArray(parsed) ? parsed as EntryT[] : [];
    }
    catch {
        return [];
    }
}

//
// Serialises and stores a JSON array.
//
function writeArray<EntryT>(store: IKeyValueStore, key: string, entries: EntryT[]): void {
    store.setItem(key, JSON.stringify(entries));
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
        await configFile.write({ databases, recentDatabaseNames });
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
// Replaces the configured-databases list wholesale (used by test setup to seed a known state).
//
export async function seedDatabases(configFile: IDatabasesConfigFile, databases: IDatabaseEntry[]): Promise<void> {
    return withConfigLock(async () => {
        const config = await configFile.read();
        await configFile.write({ ...config, databases });
    });
}

//
// Replaces the recent-databases list wholesale (used by test setup to seed a known recent state).
//
export async function seedRecentDatabases(configFile: IDatabasesConfigFile, databases: IDatabaseEntry[]): Promise<void> {
    return withConfigLock(async () => {
        const config = await configFile.read();
        await configFile.write({ ...config, recentDatabaseNames: databases.map(entry => entry.name) });
    });
}

//
// A news item that can be shown as a toast notification.
//
export interface INewsItemRecord {
    // Stable id used to track whether the item has been shown.
    id: string;

    // The toast message.
    message: string;

    // Optional toast colour variant.
    color?: "primary" | "success" | "warning" | "danger" | "neutral";

    // Optional auto-dismiss duration in ms (0/undefined means no auto-dismiss).
    duration?: number;

    // Optional link shown in the toast.
    link?: string;
}

//
// Returns the available news items.
//
export function getNews(store: IKeyValueStore): INewsItemRecord[] {
    return readArray<INewsItemRecord>(store, NEWS_KEY);
}

//
// Replaces the available news items (used by test setup to seed a known news feed).
//
export function seedNews(store: IKeyValueStore, items: INewsItemRecord[]): void {
    writeArray(store, NEWS_KEY, items);
}

//
// Returns the ids of news items already shown to (and dismissed by) the user.
//
export function getShownNewsIds(store: IKeyValueStore): string[] {
    return readArray<string>(store, SHOWN_NEWS_KEY);
}

//
// Records a news item id as shown (no-op when already present).
//
export function addShownNewsId(store: IKeyValueStore, id: string): void {
    const ids = getShownNewsIds(store);
    if (!ids.includes(id)) {
        ids.push(id);
        writeArray(store, SHOWN_NEWS_KEY, ids);
    }
}

//
// Returns the first news item that has not yet been shown, or undefined when none remain.
//
export function firstUnshownNews(store: IKeyValueStore): INewsItemRecord | undefined {
    const shown = new Set(getShownNewsIds(store));
    return getNews(store).find(item => !shown.has(item.id));
}

//
// Maps a news item to the show-notification payload shown as a toast (with the newsId so dismissal
// can mark it shown). Defaults: 'primary' colour, no auto-dismiss.
//
export function buildNewsNotification(item: INewsItemRecord): IShowNotificationData {
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
// localStorage key prefix for generic config values (the IConfig get/set store: developer mode,
// theme, collapsed-section state, etc.). Distinct from the news keys above so the two never collide.
//
export const CONFIG_KEY_PREFIX = "photosphere.config.";

//
// Returns a stored generic config value, or undefined when absent or malformed.
//
export function getConfigValue<ValueT>(store: IKeyValueStore, key: string): ValueT | undefined {
    const raw = store.getItem(CONFIG_KEY_PREFIX + key);
    if (raw === null) {
        return undefined;
    }
    try {
        return JSON.parse(raw) as ValueT;
    }
    catch {
        return undefined;
    }
}

//
// Stores a generic config value as JSON, or removes it when the value is undefined.
//
export function setConfigValue<ValueT>(store: IKeyValueStore, key: string, value: ValueT): void {
    if (value === undefined) {
        store.removeItem(CONFIG_KEY_PREFIX + key);
        return;
    }
    store.setItem(CONFIG_KEY_PREFIX + key, JSON.stringify(value));
}

//
// Clears all persisted config, used by test setup to start from a clean, deterministic state on a device
// whose storage persists between test runs. Secrets are NOT in localStorage any more (they are in the
// device keychain), so this clears only the legacy plaintext key; the platform provider clears the
// keychain secrets alongside this call.
//
export async function resetConfig(store: IKeyValueStore, configFile: IDatabasesConfigFile): Promise<void> {
    store.removeItem(LEGACY_PLAINTEXT_SECRETS_KEY);
    store.removeItem(NEWS_KEY);
    store.removeItem(SHOWN_NEWS_KEY);
    // Takes the lock so a reset cannot land between another operation's read and write, which would
    // otherwise be undone by that operation writing its pre-reset config back.
    await withConfigLock(async () => {
        await configFile.write({ databases: [], recentDatabaseNames: [] });
    });
}
