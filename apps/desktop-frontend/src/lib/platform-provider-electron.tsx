import React, { ReactNode, useCallback, useEffect, useRef } from "react";
import { PlatformContextProvider, ConfigContextProvider, createConfig, type IPlatformContext, type IDownloadAssetItem, type IShowNotificationData, convertToPng } from "user-interface";
import type { IElectronAPI, ISaveAssetItem } from "electron-defs";

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

    // Store callbacks for sync-started events
    const syncStartedCallbacksRef = useRef<Set<() => void>>(new Set());

    // Store callbacks for sync-completed events
    const syncCompletedCallbacksRef = useRef<Set<() => void>>(new Set());


    // Store callbacks for show-notification events
    const showNotificationCallbacksRef = useRef<Set<(data: IShowNotificationData) => void>>(new Set());

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

    // Set up message listener for sync-started events
    useEffect(() => {
        const handleSyncStarted = () => {
            syncStartedCallbacksRef.current.forEach(cb => cb());
        };

        electronAPI.onMessage('sync-started', handleSyncStarted);

        return () => {
            electronAPI.removeAllListeners('sync-started');
        };
    }, [electronAPI]);

    // Set up message listener for sync-completed events
    useEffect(() => {
        const handleSyncCompleted = () => {
            syncCompletedCallbacksRef.current.forEach(cb => cb());
        };

        electronAPI.onMessage('sync-completed', handleSyncCompleted); //todo: it might be better just to have one event that all these separate events are chanelled through.

        return () => {
            electronAPI.removeAllListeners('sync-completed');
        };
    }, [electronAPI]);

    // Set up message listener for show-notification events
    useEffect(() => {
        const handleShowNotification = (data: IShowNotificationData) => {
            showNotificationCallbacksRef.current.forEach(cb => cb(data));
        };

        electronAPI.onMessage('show-notification', handleShowNotification);

        return () => {
            electronAPI.removeAllListeners('show-notification');
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

    const notifyDatabaseOpened = useCallback(async (databasePath: string): Promise<void> => {
        // Notify main process to add to recent databases and update menu
        await electronAPI.notifyDatabaseOpened(databasePath);
    }, [electronAPI]);

    const notifyDatabaseClosed = useCallback(async (): Promise<void> => {
        // Notify main process to clear config and update menu
        await electronAPI.notifyDatabaseClosed();
    }, [electronAPI]);

    const onThemeChanged = useCallback((callback: (theme: 'light' | 'dark' | 'system') => void): (() => void) => {
        themeCallbacksRef.current.add(callback);
        return () => {
            themeCallbacksRef.current.delete(callback);
        };
    }, []);

    const notifyDatabaseEdited = useCallback((): void => {
        electronAPI.notifyDatabaseEdited();
    }, [electronAPI]);

    const onSyncStarted = useCallback((callback: () => void): (() => void) => {
        syncStartedCallbacksRef.current.add(callback);
        return () => {
            syncStartedCallbacksRef.current.delete(callback);
        };
    }, []);

    const onSyncCompleted = useCallback((callback: () => void): (() => void) => {
        syncCompletedCallbacksRef.current.add(callback);
        return () => {
            syncCompletedCallbacksRef.current.delete(callback);
        };
    }, []);

    const onShowNotification = useCallback((callback: (data: IShowNotificationData) => void): (() => void) => {
        showNotificationCallbacksRef.current.add(callback);
        return () => {
            showNotificationCallbacksRef.current.delete(callback);
        };
    }, []);

    const openFolder = useCallback(async (folderPath: string): Promise<void> => {
        await electronAPI.openPath(folderPath);
    }, [electronAPI]);
    const downloadAsset = useCallback(async (assetId: string, assetType: string, filename: string, _contentType: string, databasePath: string): Promise<void> => {
        await electronAPI.saveAsset(assetId, assetType, filename, databasePath);
    }, [electronAPI]);

    const downloadAssets = useCallback(async (assets: IDownloadAssetItem[], databasePath: string): Promise<void> => {
        const saveItems: ISaveAssetItem[] = assets.map(asset => ({
            assetId: asset.assetId,
            assetType: asset.assetType,
            filename: asset.filename,
        }));
        await electronAPI.saveAssets(saveItems, databasePath);
    }, [electronAPI]);

    const copyToClipboard = useCallback(async (blob: Blob, _contentType: string): Promise<void> => {
        const pngBlob = await convertToPng(blob);
        await navigator.clipboard.write([new ClipboardItem({ "image/png": pngBlob })]);
    }, []);

    const platformContext: IPlatformContext = {
        openDatabase,
        onDatabaseOpened,
        onDatabaseClosed,
        notifyDatabaseOpened,
        notifyDatabaseClosed,
        onThemeChanged,
        notifyDatabaseEdited,
        onSyncStarted,
        onSyncCompleted,
        downloadAsset,
        downloadAssets,
        copyToClipboard,
        onShowNotification,
        openFolder,
    };

    const config = createConfig(
        (key) => electronAPI.getConfig(key),
        (key, value) => electronAPI.setConfig(key, value)
    );

    return (
        <ConfigContextProvider value={config}>
            <PlatformContextProvider value={platformContext}>
                {children}
            </PlatformContextProvider>
        </ConfigContextProvider>
    );
}

