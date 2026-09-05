//
// Resetting the device: putting the app back to how it was when it was installed.
//
// The steps are ordered so that nothing is deleted while something is still using it, and so that a
// failure part-way through leaves the state a user can understand rather than a half-emptied app.
// The open database is closed first, because on a phone its files are about to be deleted. The
// database entries and the secrets go next, through the platform's own operations, so each platform
// does its own bookkeeping (the desktop menu, the databases-changed event) rather than having its
// config file pulled out from underneath it. The app's own storage is emptied last.
//
// What this must never touch is the point of the whole feature, so it is worth saying here as well
// as in the dialog: on a phone every local database lives inside the app's storage and goes with it,
// while on a desktop a database sits wherever the user put it, is removed from the list, and is left
// on disk untouched. Nothing here opens remote storage, so an S3 database is forgotten and its
// bucket is left alone. The one thing that deletes files is the platform's reset-app-storage task,
// which takes no path from anybody and can only reach the app's own two directories.
//
// Nothing here catches an error. A reset that only half happened must say so: a user who is handing
// a phone on has to know their credentials are still on it.
//

import type { IDatabaseEntry, ISharedSecretEntry } from "../context/platform-context";

//
// What the app has stored in the browser's local storage: the theme, the gallery layout, this
// client's id, the news it has already shown. Narrowed to the two operations the reset needs so it
// can be driven by an in-memory store in tests.
//
export interface IResetSettingsStore {
    //
    // The names of every value currently stored.
    //
    keys(): string[];

    //
    // Removes one stored value.
    //
    removeItem(key: string): void;
}

//
// What emptying the app's own storage removed. Mirrors the outputs of the reset-app-storage task
// without importing them: this package is shared by every platform and must not depend on the
// worker-side packages.
//
export interface IResetAppStorageOutcome {
    //
    // How many entries (files and directory trees) were removed from the app's own directories.
    //
    entriesRemoved: number;
}

//
// The operations the reset needs, passed in rather than reached for, so this runs under a unit test
// with no platform, no React and no device.
//
export interface IResetDeviceOptions {
    //
    // Closes the open database, if one is open. Called first: on a phone its files are about to go.
    //
    closeDatabase: () => Promise<void>;

    //
    // Returns every configured database entry.
    //
    getDatabases: () => Promise<IDatabaseEntry[]>;

    //
    // Removes one database entry from the configured list, and from the recents with it.
    //
    removeDatabaseEntry: (name: string) => Promise<void>;

    //
    // Returns every secret held in the device's vault.
    //
    listSecrets: () => Promise<ISharedSecretEntry[]>;

    //
    // Deletes one secret from the vault.
    //
    deleteSecret: (name: string) => Promise<void>;

    //
    // The app's own local storage, cleared wholesale: every key in it belongs to this app.
    //
    settingsStore: IResetSettingsStore;

    //
    // Empties the app's own config and cache directories, which on a phone are its storage sandbox,
    // and reports what went.
    //
    resetAppStorage: () => Promise<IResetAppStorageOutcome>;
}

//
// What the reset removed, for the confirmation the user is shown and the line written to the log.
//
export interface IResetDeviceResult {
    //
    // How many database entries were removed from the list.
    //
    databasesRemoved: number;

    //
    // How many secrets were deleted from the vault.
    //
    secretsRemoved: number;

    //
    // How many stored interface settings were cleared.
    //
    settingsRemoved: number;

    //
    // How many entries were removed from the app's own storage directories.
    //
    storageEntriesRemoved: number;
}

//
// Puts the app back to how it was when it was installed, and reports what that removed.
//
export async function resetDevice(options: IResetDeviceOptions): Promise<IResetDeviceResult> {
    await options.closeDatabase();

    const databases = await options.getDatabases();
    for (const database of databases) {
        await options.removeDatabaseEntry(database.name);
    }

    const secrets = await options.listSecrets();
    for (const secret of secrets) {
        await options.deleteSecret(secret.name);
    }

    // The keys are read out before any of them is removed: a store that reports its keys live would
    // otherwise be modified while it was being walked.
    const settingsKeys = options.settingsStore.keys();
    for (const settingsKey of settingsKeys) {
        options.settingsStore.removeItem(settingsKey);
    }

    const storageOutcome = await options.resetAppStorage();

    return {
        databasesRemoved: databases.length,
        secretsRemoved: secrets.length,
        settingsRemoved: settingsKeys.length,
        storageEntriesRemoved: storageOutcome.entriesRemoved,
    };
}
