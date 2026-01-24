import React, { ReactNode, useCallback, useEffect, useRef } from "react";
import { PlatformContextProvider, type IPlatformContext } from "user-interface";
import type { IElectronAPI } from "electron-defs";

export interface IPlatformProviderElectronProps {
    children: ReactNode | ReactNode[];
    electronAPI: IElectronAPI;
}

//
// Electron-specific platform context provider.
// Provides database opening functionality via Electron IPC.
//
export function PlatformProviderElectron({ children, electronAPI }: IPlatformProviderElectronProps) {
    // Store callbacks for database-opened events
    const callbacksRef = useRef<Set<(databasePath: string) => void>>(new Set());

    // Set up message listener for database-opened events
    useEffect(() => {
        const handleDatabaseOpened = (databasePath: string) => {
            // Notify all subscribers
            callbacksRef.current.forEach(callback => {
                callback(databasePath);
            });
        };

        electronAPI.onMessage('database-opened', handleDatabaseOpened);

        return () => {
            electronAPI.removeAllListeners('database-opened');
        };
    }, [electronAPI]);

    const openDatabase = useCallback(async (): Promise<void> => {
        await electronAPI.openDatabase();
    }, [electronAPI]);

    const onDatabaseOpened = useCallback((callback: (databasePath: string) => void): (() => void) => {
        // Add callback to set
        callbacksRef.current.add(callback);

        // Return unsubscribe function
        return () => {
            callbacksRef.current.delete(callback);
        };
    }, []);

    const getRecentDatabases = useCallback(async (): Promise<string[]> => {
        return await electronAPI.getRecentDatabases();
    }, [electronAPI]);

    const removeDatabase = useCallback(async (databasePath: string): Promise<void> => {
        return await electronAPI.removeDatabase(databasePath);
    }, [electronAPI]);

    const addRecentDatabase = useCallback(async (databasePath: string): Promise<void> => {
        return await electronAPI.addRecentDatabase(databasePath);
    }, [electronAPI]);

    const clearLastDatabase = useCallback(async (): Promise<void> => {
        return await electronAPI.clearLastDatabase();
    }, [electronAPI]);

    const platformContext: IPlatformContext = {
        openDatabase,
        onDatabaseOpened,
        getRecentDatabases,
        removeDatabase,
        addRecentDatabase,
        clearLastDatabase,
    };

    return (
        <PlatformContextProvider value={platformContext}>
            {children}
        </PlatformContextProvider>
    );
}

