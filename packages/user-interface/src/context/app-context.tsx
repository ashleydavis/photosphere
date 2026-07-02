import React, { ReactNode, createContext, useContext, useEffect, useState } from "react";
import { usePlatform, type IDatabaseEntry, type ISharedSecretEntry } from "./platform-context";
import { useConfig } from "./config-context";
import { log } from "utils";
import type { IConflictResolution } from "api";

//
// Config persistence key for the developer-mode flag.
//
const DEVELOPER_MODE_CONFIG_KEY = "developerMode";

//
// Config persistence key for the FPS-indicator flag. Reused from the former
// desktop Developer menu so previously persisted values continue to apply.
//
const SHOW_FPS_INDICATOR_CONFIG_KEY = "showFpsIndicator";

//
// Config persistence key for the developer-tools open flag. When true the
// developer tools are reopened on startup.
//
const DEV_TOOLS_OPEN_CONFIG_KEY = "devToolsOpen";

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

    //
    // True while developer mode is enabled (reveals developer tools in the UI).
    //
    developerMode: boolean;

    //
    // Turns developer mode on and persists the flag.
    //
    enableDeveloperMode: () => void;

    //
    // Turns developer mode off and persists the flag.
    //
    disableDeveloperMode: () => void;

    //
    // True while the FPS-indicator overlay should be shown.
    //
    showFpsIndicator: boolean;

    //
    // Toggles the FPS-indicator overlay and persists the flag.
    //
    toggleShowFpsIndicator: () => void;

    //
    // True while the developer tools are open. Persisted and reopened on startup.
    //
    devToolsOpen: boolean;

    //
    // Toggles the developer tools (native inspector on desktop, in-page console
    // on web/mobile), persisting the new state so it is reapplied on startup.
    //
    toggleDevTools: () => void;
}

const AppContext = createContext<IAppContext | undefined>(undefined);

export interface IProps {
    children: ReactNode | ReactNode[];
}

export function AppContextProvider({ children }: IProps) {
    const platform = usePlatform();
    const config = useConfig();

    //
    // Configured database entries.
    //
    const [dbs, setDbs] = useState<IDatabaseEntry[]>([]);

    //
    // All shared secret entries in the vault.
    //
    const [secrets, setSecrets] = useState<ISharedSecretEntry[]>([]);

    //
    // Whether developer mode is currently enabled. Loaded from persistent config on mount.
    //
    const [developerMode, setDeveloperMode] = useState<boolean>(false);

    //
    // Whether the FPS-indicator overlay is currently shown. Loaded from persistent config on mount.
    //
    const [showFpsIndicator, setShowFpsIndicator] = useState<boolean>(false);

    //
    // Whether the developer tools are currently open. Loaded from persistent config on mount
    // and reapplied to the platform so the tools reopen on startup.
    //
    const [devToolsOpen, setDevToolsOpen] = useState<boolean>(false);

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

    //
    // Enables developer mode and persists the change (fire and forget).
    //
    function enableDeveloperMode(): void {
        setDeveloperMode(true);
        config.set<boolean>(DEVELOPER_MODE_CONFIG_KEY, true)
            .catch(err => log.exception("Failed to persist developer mode:", err as Error));
        log.event("Developer mode enabled");
    }

    //
    // Disables developer mode and persists the change (fire and forget).
    //
    function disableDeveloperMode(): void {
        setDeveloperMode(false);
        config.set<boolean>(DEVELOPER_MODE_CONFIG_KEY, false)
            .catch(err => log.exception("Failed to persist developer mode:", err as Error));
        log.event("Developer mode disabled");
    }

    //
    // Toggles the FPS indicator and persists the change (fire and forget).
    //
    function toggleShowFpsIndicator(): void {
        const nextValue = !showFpsIndicator;
        setShowFpsIndicator(nextValue);
        config.set<boolean>(SHOW_FPS_INDICATOR_CONFIG_KEY, nextValue)
            .catch(err => log.exception("Failed to persist FPS indicator setting:", err as Error));
        log.event(`FPS indicator ${nextValue ? "enabled" : "disabled"}`);
    }

    //
    // Toggles the developer tools and persists the new state (fire and forget).
    // The platform applies the actual inspector; the persisted flag reopens it on startup.
    //
    function toggleDevTools(): void {
        const nextValue = !devToolsOpen;
        setDevToolsOpen(nextValue);
        platform.toggleDevTools();
        config.set<boolean>(DEV_TOOLS_OPEN_CONFIG_KEY, nextValue)
            .catch(err => log.exception("Failed to persist developer tools setting:", err as Error));
        log.event(`Developer tools ${nextValue ? "opened" : "closed"}`);
    }

    useEffect(() => {
        refresh().catch(err => {
            log.exception(`Failed to load app data:`, err as Error);
        });
    }, [platform]);

    useEffect(() => {
        config.get<boolean>(DEVELOPER_MODE_CONFIG_KEY).then(value => {
            if (value !== undefined) {
                setDeveloperMode(value);
            }
        });
    }, []);

    useEffect(() => {
        config.get<boolean>(SHOW_FPS_INDICATOR_CONFIG_KEY).then(value => {
            if (value !== undefined) {
                setShowFpsIndicator(value);
            }
        });
    }, []);

    useEffect(() => {
        config.get<boolean>(DEV_TOOLS_OPEN_CONFIG_KEY).then(value => {
            if (value === true) {
                setDevToolsOpen(true);
                // Reopen the developer tools on startup. Both inspectors start closed
                // after a restart, so a single toggle brings them back to the open state.
                platform.toggleDevTools();
            }
        });
    }, []);

    useEffect(() => {
        return platform.onDatabaseOpened(() => {
            refreshDbs().catch(err => {
                log.exception(`Failed to reload databases after database opened:`, err as Error);
            });
        });
    }, [platform]);

    useEffect(() => {
        return platform.onDatabasesChanged(() => {
            refreshDbs().catch(err => {
                log.exception(`Failed to reload databases after databases changed:`, err as Error);
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
        developerMode,
        enableDeveloperMode,
        disableDeveloperMode,
        showFpsIndicator,
        toggleShowFpsIndicator,
        devToolsOpen,
        toggleDevTools,
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
