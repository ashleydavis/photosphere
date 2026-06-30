import type { IDatabaseEntry, ISharedSecretEntry, IShowNotificationData } from "user-interface";

//
// Client-side persistence for the mobile app's configured-databases and recent-databases lists.
//
// On desktop these lists live in `~/.config/photosphere/databases.toml`, read by the main process.
// The mobile WebView has no filesystem access, so the lists are persisted in WebView localStorage
// instead. This module holds the pure store logic (operating on a small key/value interface) so it
// is unit-testable without a real WebView, and so the platform provider and the test driver share
// one source of truth for the storage keys and shapes.
//

//
// localStorage key for the configured-databases list.
//
export const DATABASES_KEY = "photosphere.databases";

//
// localStorage key for the recently-opened-databases list.
//
export const RECENT_DATABASES_KEY = "photosphere.recentDatabases";

//
// localStorage key for the secrets list (cleared by resetConfig; secret accessors land with the
// secrets feature).
//
export const SECRETS_KEY = "photosphere.secrets";

//
// localStorage key for the available news items (seeded in tests; would be fetched in production).
//
export const NEWS_KEY = "photosphere.news";

//
// localStorage key for the set of already-shown news item ids.
//
export const SHOWN_NEWS_KEY = "photosphere.shownNews";

//
// The minimal key/value interface the store needs (a subset of the Web Storage API). Abstracted so
// unit tests can supply an in-memory implementation.
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
// Returns the configured databases.
//
export function getDatabases(store: IKeyValueStore): IDatabaseEntry[] {
    return readArray<IDatabaseEntry>(store, DATABASES_KEY);
}

//
// Adds (or replaces, by case-insensitive name) a database entry, returning the stored entry.
//
export function addDatabase(store: IKeyValueStore, entry: IDatabaseEntry): IDatabaseEntry {
    const remaining = getDatabases(store).filter(existing => existing.name.toLowerCase() !== entry.name.toLowerCase());
    remaining.push(entry);
    writeArray(store, DATABASES_KEY, remaining);
    return entry;
}

//
// Updates the entry matching originalName (case-insensitive) to the new entry.
//
export function updateDatabase(store: IKeyValueStore, originalName: string, entry: IDatabaseEntry): void {
    const updated = getDatabases(store).map(existing =>
        existing.name.toLowerCase() === originalName.toLowerCase() ? entry : existing);
    writeArray(store, DATABASES_KEY, updated);
}

//
// Removes the entry with the given name (case-insensitive).
//
export function removeDatabase(store: IKeyValueStore, name: string): void {
    writeArray(store, DATABASES_KEY, getDatabases(store).filter(existing => existing.name.toLowerCase() !== name.toLowerCase()));
}

//
// Finds a database entry by name (case-insensitive).
//
export function findDatabase(store: IKeyValueStore, name: string): IDatabaseEntry | undefined {
    return getDatabases(store).find(existing => existing.name.toLowerCase() === name.toLowerCase());
}

//
// Finds a database entry by its path.
//
export function findDatabaseByPath(store: IKeyValueStore, databasePath: string): IDatabaseEntry | undefined {
    return getDatabases(store).find(existing => existing.path === databasePath);
}

//
// Sets (or clears) the replication origin on the database entry with the given path.
//
export function setDatabaseOrigin(store: IKeyValueStore, databasePath: string, origin: string | undefined): void {
    const updated = getDatabases(store).map(existing =>
        existing.path === databasePath ? { ...existing, origin } : existing);
    writeArray(store, DATABASES_KEY, updated);
}

//
// Returns the recently-opened databases (most-recent first).
//
export function getRecentDatabases(store: IKeyValueStore): IDatabaseEntry[] {
    return readArray<IDatabaseEntry>(store, RECENT_DATABASES_KEY);
}

//
// Records a database as most-recently opened (de-duplicated by path, moved to the front).
//
export function addRecentDatabase(store: IKeyValueStore, entry: IDatabaseEntry): void {
    const remaining = getRecentDatabases(store).filter(existing => existing.path !== entry.path);
    remaining.unshift(entry);
    writeArray(store, RECENT_DATABASES_KEY, remaining);
}

//
// Replaces the recent-databases list wholesale (used by test setup to seed a known recent state).
//
export function seedRecentDatabases(store: IKeyValueStore, databases: IDatabaseEntry[]): void {
    writeArray(store, RECENT_DATABASES_KEY, databases);
}

//
// Removes a database from the recent list by name (case-insensitive).
//
export function removeRecentDatabase(store: IKeyValueStore, name: string): void {
    writeArray(store, RECENT_DATABASES_KEY, getRecentDatabases(store).filter(existing => existing.name.toLowerCase() !== name.toLowerCase()));
}

//
// Replaces the configured-databases list wholesale (used by test setup to seed a known state).
//
export function seedDatabases(store: IKeyValueStore, databases: IDatabaseEntry[]): void {
    writeArray(store, DATABASES_KEY, databases);
}

//
// A stored secret: its entry (name + type) plus its secret value (PEM, API key, or JSON for s3).
//
export interface IStoredSecret {
    // The secret entry (name is the unique key; type is the category).
    entry: ISharedSecretEntry;

    // The secret value as a string (the vault would hold this on desktop).
    value: string;
}

//
// Returns the configured secret entries (values omitted, matching listSecrets on desktop).
//
export function listSecrets(store: IKeyValueStore): ISharedSecretEntry[] {
    return readArray<IStoredSecret>(store, SECRETS_KEY).map(stored => stored.entry);
}

//
// Adds a secret, returning the stored entry. Throws (with the exact message the desktop provider
// uses) when a secret of the same name already exists, so the duplicate-name flow behaves identically.
//
export function addSecret(store: IKeyValueStore, entry: ISharedSecretEntry, value: string): ISharedSecretEntry {
    const stored = readArray<IStoredSecret>(store, SECRETS_KEY);
    if (stored.some(existing => existing.entry.name === entry.name)) {
        throw new Error(`A secret named '${entry.name}' already exists.`);
    }
    stored.push({ entry, value });
    writeArray(store, SECRETS_KEY, stored);
    return entry;
}

//
// Updates the secret matching originalName: replaces its entry, and its value when one is given.
//
export function updateSecret(store: IKeyValueStore, originalName: string, entry: ISharedSecretEntry, value?: string): void {
    const stored = readArray<IStoredSecret>(store, SECRETS_KEY);
    const updated = stored.map(existing =>
        existing.entry.name === originalName
            ? { entry, value: value !== undefined ? value : existing.value }
            : existing);
    writeArray(store, SECRETS_KEY, updated);
}

//
// Removes the secret with the given name.
//
export function deleteSecret(store: IKeyValueStore, name: string): void {
    writeArray(store, SECRETS_KEY, readArray<IStoredSecret>(store, SECRETS_KEY).filter(existing => existing.entry.name !== name));
}

//
// Returns the stored value for a secret name, or undefined when not present.
//
export function getSecretValue(store: IKeyValueStore, name: string): string | undefined {
    const found = readArray<IStoredSecret>(store, SECRETS_KEY).find(existing => existing.entry.name === name);
    return found?.value;
}

//
// Replaces the secrets list wholesale (used by test setup to seed a known secret state).
//
export function seedSecrets(store: IKeyValueStore, secrets: IStoredSecret[]): void {
    writeArray(store, SECRETS_KEY, secrets);
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
// theme, collapsed-section state, etc.). Distinct from the list keys above so the two never collide.
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
// Clears all persisted config (databases, recent databases, secrets), used by test setup to start
// from a clean, deterministic state on a device whose storage persists between test runs.
//
export function resetConfig(store: IKeyValueStore): void {
    store.removeItem(DATABASES_KEY);
    store.removeItem(RECENT_DATABASES_KEY);
    store.removeItem(SECRETS_KEY);
    store.removeItem(NEWS_KEY);
    store.removeItem(SHOWN_NEWS_KEY);
}
