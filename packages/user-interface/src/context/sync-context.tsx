import React, { ReactNode, createContext, useContext, useEffect, useState } from "react";
import { usePlatform, type INetworkStatus } from "./platform-context";
import { useConfig } from "./config-context";
import { computeSyncAllowed } from "../lib/sync-gate";
import { log } from "utils";

//
// Config persistence key for the master sync-enabled flag. Defaults to true.
//
const SYNC_ENABLED_CONFIG_KEY = "syncEnabled";

//
// Config persistence key for the Wi-Fi-only sync flag. Defaults to true so
// syncing is restricted to Wi-Fi out of the box.
//
const SYNC_ONLY_ON_WIFI_CONFIG_KEY = "syncOnlyOnWifi";

//
// Reactive sync configuration: whether syncing is enabled at all and whether it
// is restricted to Wi-Fi. Both values persist to config so they survive a
// restart. The provider also watches the network and pushes the combined gate
// decision to the host scheduler so automatic syncs only run when permitted.
//
export interface ISyncContext {
    //
    // True while automatic syncing is enabled (master switch).
    //
    syncEnabled: boolean;

    //
    // Toggles the master sync switch and persists the flag.
    //
    toggleSyncEnabled: () => void;

    //
    // True while automatic syncing is restricted to Wi-Fi connections.
    //
    syncOnlyOnWifi: boolean;

    //
    // Toggles the Wi-Fi-only restriction and persists the flag.
    //
    toggleSyncOnlyOnWifi: () => void;
}

const SyncContext = createContext<ISyncContext | undefined>(undefined);

//
// Props for the sync-context provider.
//
export interface ISyncContextProviderProps {
    //
    // The subtree that can read the sync configuration.
    //
    children: ReactNode | ReactNode[];
}

//
// Provides the reactive sync configuration to its subtree and keeps the host
// scheduler's sync gate up to date.
//
export function SyncContextProvider({ children }: ISyncContextProviderProps) {
    const platform = usePlatform();
    const config = useConfig();

    //
    // Whether syncing is enabled. Loaded from persistent config on mount (default true).
    //
    const [syncEnabled, setSyncEnabled] = useState<boolean>(true);

    //
    // Whether syncing is restricted to Wi-Fi. Loaded from persistent config on mount (default true).
    //
    const [syncOnlyOnWifi, setSyncOnlyOnWifi] = useState<boolean>(true);

    //
    // The current network status. Seeded on mount and updated on network changes.
    //
    const [networkStatus, setNetworkStatus] = useState<INetworkStatus>({ connected: true, connectionType: "unknown" });

    //
    // Toggles the master sync switch and persists the change (fire and forget).
    //
    function toggleSyncEnabled(): void {
        const nextValue = !syncEnabled;
        setSyncEnabled(nextValue);
        config.set<boolean>(SYNC_ENABLED_CONFIG_KEY, nextValue)
            .catch(err => log.exception("Failed to persist sync-enabled setting:", err as Error));
        log.event(`Syncing ${nextValue ? "enabled" : "disabled"}`);
    }

    //
    // Toggles the Wi-Fi-only restriction and persists the change (fire and forget).
    //
    function toggleSyncOnlyOnWifi(): void {
        const nextValue = !syncOnlyOnWifi;
        setSyncOnlyOnWifi(nextValue);
        config.set<boolean>(SYNC_ONLY_ON_WIFI_CONFIG_KEY, nextValue)
            .catch(err => log.exception("Failed to persist Wi-Fi-only setting:", err as Error));
        log.event(`Sync Wi-Fi-only ${nextValue ? "enabled" : "disabled"}`);
    }

    useEffect(() => {
        config.get<boolean>(SYNC_ENABLED_CONFIG_KEY).then(value => {
            if (value !== undefined) {
                setSyncEnabled(value);
            }
        });
    }, []);

    useEffect(() => {
        config.get<boolean>(SYNC_ONLY_ON_WIFI_CONFIG_KEY).then(value => {
            if (value !== undefined) {
                setSyncOnlyOnWifi(value);
            }
        });
    }, []);

    //
    // Seed the network status on mount and subscribe to subsequent changes so
    // the gate reflects online/offline (and, on mobile, connection-type) changes.
    //
    useEffect(() => {
        platform.getNetworkStatus().then(setNetworkStatus);
        return platform.onNetworkStatusChange(setNetworkStatus);
    }, [platform]);

    //
    // Push the combined gate decision to the host scheduler whenever an input
    // changes (and on mount), so automatic syncs only run when permitted.
    //
    useEffect(() => {
        platform.setSyncAllowed(computeSyncAllowed({
            syncEnabled,
            syncOnlyOnWifi,
            connected: networkStatus.connected,
            connectionType: networkStatus.connectionType,
        }));
    }, [platform, syncEnabled, syncOnlyOnWifi, networkStatus]);

    const value: ISyncContext = {
        syncEnabled,
        toggleSyncEnabled,
        syncOnlyOnWifi,
        toggleSyncOnlyOnWifi,
    };

    return (
        <SyncContext.Provider value={value} >
            {children}
        </SyncContext.Provider>
    );
}

//
// Get the sync context.
//
export function useSync() {
    const context = useContext(SyncContext);
    if (!context) {
        throw new Error(`SyncContext is not set! Add SyncContextProvider to the component tree.`);
    }
    return context;
}
