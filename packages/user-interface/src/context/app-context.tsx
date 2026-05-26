import React, { ReactNode, createContext, useContext, useEffect, useState } from "react";
import { usePlatform, type IDatabaseEntry, type ISharedSecretEntry } from "./platform-context";
import { log } from "utils";
import type { IConflictResolution } from "api";

//
// Application-wide reactive data layer for configured databases and shared secrets.
// Pages and dialogs read `dbs` / `secrets` from here and call the mutation methods
// to add, update or remove entries. Each mutation refreshes the relevant slice of
// state, so consumers re-render without any explicit refresh wiring.
//
export interface IAppContext {
    //
    // Configured database entries.
    //
    dbs: IDatabaseEntry[];

    //
    // All shared secret entries in the vault.
    //
    secrets: ISharedSecretEntry[];

    //
    // Re-reads both lists from the platform. Used by manual refresh buttons.
    //
    refresh: () => Promise<void>;

    //
    // Adds a new database entry and returns the created entry.
    //
    addDatabase: (entry: IDatabaseEntry) => Promise<IDatabaseEntry>;

    //
    // Updates an existing database entry. `originalName` is the name before any rename.
    //
    updateDatabase: (originalName: string, entry: IDatabaseEntry) => Promise<void>;

    //
    // Removes a database entry by name.
    //
    removeDatabase: (name: string) => Promise<void>;

    //
    // Adds a new shared secret to the vault and returns the created entry.
    //
    addSecret: (entry: ISharedSecretEntry, value: string) => Promise<ISharedSecretEntry>;

    //
    // Updates an existing shared secret. `originalName` is the prior vault key, used
    // to delete the old entry when the secret is renamed.
    //
    updateSecret: (originalName: string, entry: ISharedSecretEntry, value?: string) => Promise<void>;

    //
    // Deletes a shared secret by name.
    //
    deleteSecret: (name: string) => Promise<void>;

    //
    // Imports a LAN-share payload (database with bundled secrets, or a single secret)
    // into the local config and vault.
    //
    importSharePayload: (payload: unknown, conflictResolutions: Record<string, IConflictResolution>) => Promise<void>;
}

const AppContext = createContext<IAppContext | undefined>(undefined);

export interface IProps {
    children: ReactNode | ReactNode[];
}

export function AppContextProvider({ children }: IProps) {
    const platform = usePlatform();

    //
    // Configured database entries.
    //
    const [dbs, setDbs] = useState<IDatabaseEntry[]>([]);

    //
    // All shared secret entries in the vault.
    //
    const [secrets, setSecrets] = useState<ISharedSecretEntry[]>([]);

    //
    // Re-reads the database list from the platform.
    //
    async function refreshDbs(): Promise<void> {
        const databases = await platform.getDatabases();
        setDbs(databases);
    }

    //
    // Re-reads the shared-secrets list from the platform.
    //
    async function refreshSecrets(): Promise<void> {
        const entries = await platform.listSecrets();
        setSecrets(entries);
    }

    //
    // Re-reads both lists in parallel.
    //
    async function refresh(): Promise<void> {
        await Promise.all([refreshDbs(), refreshSecrets()]);
    }

    //
    // Adds a new database entry and returns the created entry.
    //
    async function addDatabase(entry: IDatabaseEntry): Promise<IDatabaseEntry> {
        const created = await platform.addDatabase(entry);
        await refreshDbs();
        return created;
    }

    //
    // Updates an existing database entry.
    //
    async function updateDatabase(originalName: string, entry: IDatabaseEntry): Promise<void> {
        await platform.updateDatabase(originalName, entry);
        await refreshDbs();
    }

    //
    // Removes a database entry by name.
    //
    async function removeDatabase(name: string): Promise<void> {
        await platform.removeDatabaseEntry(name);
        await refreshDbs();
    }

    //
    // Adds a new shared secret to the vault.
    //
    async function addSecret(entry: ISharedSecretEntry, value: string): Promise<ISharedSecretEntry> {
        const created = await platform.addSecret(entry, value);
        await refreshSecrets();
        return created;
    }

    //
    // Updates an existing shared secret.
    //
    async function updateSecret(originalName: string, entry: ISharedSecretEntry, value?: string): Promise<void> {
        await platform.updateSecret(originalName, entry, value);
        await refreshSecrets();
    }

    //
    // Deletes a shared secret by name.
    //
    async function deleteSecret(name: string): Promise<void> {
        await platform.deleteSecret(name);
        await refreshSecrets();
    }

    //
    // Imports a LAN-share payload. Refreshes both lists since a single payload can
    // create a database entry and one or more bundled secrets.
    //
    async function importSharePayload(payload: unknown, conflictResolutions: Record<string, IConflictResolution>): Promise<void> {
        await platform.importSharePayload(payload, conflictResolutions);
        await refresh();
    }

    useEffect(() => {
        refresh().catch(err => {
            log.exception(`Failed to load app data:`, err as Error);
        });
    }, [platform]);

    useEffect(() => {
        return platform.onDatabaseOpened(() => {
            refreshDbs().catch(err => {
                log.exception(`Failed to reload databases after database opened:`, err as Error);
            });
        });
    }, [platform]);

    const value: IAppContext = {
        dbs,
        secrets,
        refresh,
        addDatabase,
        updateDatabase,
        removeDatabase,
        addSecret,
        updateSecret,
        deleteSecret,
        importSharePayload,
    };

    return (
        <AppContext.Provider value={value} >
            {children}
        </AppContext.Provider>
    );
}

//
// Get the app context.
//
export function useApp() {
    const context = useContext(AppContext);
    if (!context) {
        throw new Error(`AppContext is not set! Add AppContext to the component tree.`);
    }
    return context;
}
