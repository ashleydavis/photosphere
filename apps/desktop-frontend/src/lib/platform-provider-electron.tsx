import React, { ReactNode, useCallback, useEffect, useRef } from "react";
import { PlatformContextProvider, ConfigContextProvider, createConfig, type IPlatformContext, type IImportSession, type IToolsStatus, type IDownloadAssetItem, type IShowNotificationData, convertToPng } from "user-interface";
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

    // Store callbacks for menu actions, keyed by action name
    const menuActionCallbacksRef = useRef<Map<string, Set<() => void>>>(new Map());

    // Store callbacks for sync-started events
    const syncStartedCallbacksRef = useRef<Set<() => void>>(new Set());

    // Store callbacks for sync-completed events
    const syncCompletedCallbacksRef = useRef<Set<() => void>>(new Set());


    // Store callbacks for show-notification events
    const showNotificationCallbacksRef = useRef<Set<(data: IShowNotificationData) => void>>(new Set());

    // Store callbacks for task-message events
    const taskMessageCallbacksRef = useRef<Set<(taskId: string, message: Record<string, unknown>) => void>>(new Set());

    // Store callbacks for task-completed events
    const taskCompleteCallbacksRef = useRef<Set<(taskId: string, result: Record<string, unknown>) => void>>(new Set());

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

        electronAPI.onMessage('sync-completed', handleSyncCompleted);

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

    // Set up message listener for menu-action events
    useEffect(() => {
        const handleMenuAction = (action: string) => {
            menuActionCallbacksRef.current.get(action)?.forEach(cb => cb());
        };

        electronAPI.onMessage('menu-action', handleMenuAction);

        return () => {
            electronAPI.removeAllListeners('menu-action');
        };
    }, [electronAPI]);

    // Set up message listener for task-message events (import progress)
    useEffect(() => {
        const handleTaskMessage = (data: { taskId: string; message: Record<string, unknown> }) => {
            taskMessageCallbacksRef.current.forEach(cb => cb(data.taskId, data.message));
        };

        electronAPI.onMessage('task-message', handleTaskMessage);

        return () => {
            // Note: removeAllListeners is intentionally not called here because
            // WorkerPoolElectronRenderer also registers a listener for 'task-message'
            // and removing all listeners would break it.
        };
    }, [electronAPI]);

    // Set up message listener for task-completed events (import completion)
    useEffect(() => {
        const handleTaskCompleted = (data: { taskId: string; result: Record<string, unknown> }) => {
            taskCompleteCallbacksRef.current.forEach(cb => cb(data.taskId, data.result));
        };

        electronAPI.onMessage('task-completed', handleTaskCompleted);

        return () => {
            // Note: removeAllListeners is intentionally not called here because
            // WorkerPoolElectronRenderer also registers a listener for 'task-completed'
            // and removing all listeners would break it.
        };
    }, [electronAPI]);

    const openDatabase = useCallback(async (): Promise<void> => {
        await electronAPI.openDatabase();
    }, [electronAPI]);

    const createDatabase = useCallback(async (): Promise<void> => {
        await electronAPI.createDatabase();
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

    const onMenuAction = useCallback((action: string, callback: () => void): (() => void) => {
        if (!menuActionCallbacksRef.current.has(action)) {
            menuActionCallbacksRef.current.set(action, new Set());
        }
        menuActionCallbacksRef.current.get(action)!.add(callback);
        return () => {
            menuActionCallbacksRef.current.get(action)?.delete(callback);
        };
    }, []);

    const openFolder = useCallback(async (folderPath: string): Promise<void> => {
        await electronAPI.openPath(folderPath);
    }, [electronAPI]);

    const importAssets = useCallback(async (paths?: string[]): Promise<IImportSession | undefined> => {
        return await electronAPI.importAssets(paths);
    }, [electronAPI]);

    const getPathForFile = useCallback((file: File): string | undefined => {
        return electronAPI.getPathForFile(file);
    }, [electronAPI]);

    const checkTools = useCallback(async (): Promise<IToolsStatus> => {
        return await electronAPI.checkTools();
    }, [electronAPI]);

    const onTaskMessage = useCallback((handler: (taskId: string, message: Record<string, unknown>) => void): (() => void) => {
        taskMessageCallbacksRef.current.add(handler);
        return () => {
            taskMessageCallbacksRef.current.delete(handler);
        };
    }, []);

    const onTaskComplete = useCallback((handler: (taskId: string, result: Record<string, unknown>) => void): (() => void) => {
        taskCompleteCallbacksRef.current.add(handler);
        return () => {
            taskCompleteCallbacksRef.current.delete(handler);
        };
    }, []);

    const cancelTasks = useCallback(async (sessionId: string): Promise<void> => {
        electronAPI.cancelTasks(sessionId);
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
        createDatabase,
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
        onMenuAction,
        importAssets,
        getPathForFile,
        checkTools,
        onTaskMessage,
        onTaskComplete,
        cancelTasks,
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

