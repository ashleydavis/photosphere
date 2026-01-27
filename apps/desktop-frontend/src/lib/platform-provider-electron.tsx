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
    const openedCallbacksRef = useRef<Set<(databasePath: string) => void>>(new Set());
    
    // Store callbacks for database-closed events
    const closedCallbacksRef = useRef<Set<() => void>>(new Set());

    // Store callbacks for theme-changed events
    const themeCallbacksRef = useRef<Set<(theme: 'light' | 'dark' | 'system') => void>>(new Set());

    // Set up message listener for database-opened events
    useEffect(() => {
        const handleDatabaseOpened = (databasePath: string) => {
            // Notify all subscribers
            openedCallbacksRef.current.forEach(callback => {
                callback(databasePath);
            });
        };

        electronAPI.onMessage('database-opened', handleDatabaseOpened);

        return () => {
            electronAPI.removeAllListeners('database-opened');
        };
    }, [electronAPI]);

    // Set up message listener for database-closed events
    useEffect(() => {
        const handleDatabaseClosed = () => {
            // Notify all subscribers
            closedCallbacksRef.current.forEach(callback => {
                callback();
            });
        };

        electronAPI.onMessage('database-closed', handleDatabaseClosed);

        return () => {
            electronAPI.removeAllListeners('database-closed');
        };
    }, [electronAPI]);

    // Set up message listener for theme-changed events
    useEffect(() => {
        const handleThemeChanged = (theme: 'light' | 'dark' | 'system') => {
            // Notify all subscribers
            themeCallbacksRef.current.forEach(callback => {
                callback(theme);
            });
        };

        electronAPI.onMessage('theme-changed', handleThemeChanged);

        return () => {
            electronAPI.removeAllListeners('theme-changed');
        };
    }, [electronAPI]);

    const openDatabase = useCallback(async (): Promise<void> => {
        await electronAPI.openDatabase();
    }, [electronAPI]);

    const onDatabaseOpened = useCallback((callback: (databasePath: string) => void): (() => void) => {
        // Add callback to set
        openedCallbacksRef.current.add(callback);

        // Return unsubscribe function
        return () => {
            openedCallbacksRef.current.delete(callback);
        };
    }, []);

    const onDatabaseClosed = useCallback((callback: () => void): (() => void) => {
        // Add callback to set
        closedCallbacksRef.current.add(callback);

        // Return unsubscribe function
        return () => {
            closedCallbacksRef.current.delete(callback);
        };
    }, []);

    const getRecentDatabases = useCallback(async (): Promise<string[]> => {
        return await electronAPI.getRecentDatabases();
    }, [electronAPI]);

    const removeDatabase = useCallback(async (databasePath: string): Promise<void> => {
        return await electronAPI.removeDatabase(databasePath);
    }, [electronAPI]);

    const notifyDatabaseOpened = useCallback(async (databasePath: string): Promise<void> => {
        // Notify main process to add to recent databases and update menu
        await electronAPI.notifyDatabaseOpened(databasePath);
    }, [electronAPI]);

    const notifyDatabaseClosed = useCallback(async (): Promise<void> => {
        // Notify main process to clear config and update menu
        await electronAPI.notifyDatabaseClosed();
    }, [electronAPI]);

    const getTheme = useCallback(async (): Promise<'light' | 'dark' | 'system'> => {
        return await electronAPI.getTheme();
    }, [electronAPI]);

    const setTheme = useCallback(async (theme: 'light' | 'dark' | 'system'): Promise<void> => {
        await electronAPI.setTheme(theme);
    }, [electronAPI]);

    const onThemeChanged = useCallback((callback: (theme: 'light' | 'dark' | 'system') => void): (() => void) => {
        // Add callback to set
        themeCallbacksRef.current.add(callback);

        // Return unsubscribe function
        return () => {
            themeCallbacksRef.current.delete(callback);
        };
    }, []);

    const platformContext: IPlatformContext = {
        openDatabase,
        onDatabaseOpened,
        onDatabaseClosed,
        getRecentDatabases,
        removeDatabase,
        notifyDatabaseOpened,
        notifyDatabaseClosed,
        getTheme,
        setTheme,
        onThemeChanged,
    };

    return (
        <PlatformContextProvider value={platformContext}>
            {children}
        </PlatformContextProvider>
    );
}

