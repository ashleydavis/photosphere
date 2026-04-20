import React, { ReactNode, useCallback, useEffect, useRef } from "react";
import { PlatformContextProvider, ConfigContextProvider, createConfig, type IPlatformContext, type IImportSession, type IToolsStatus, type IDownloadAssetItem, type IShowNotificationData, convertToPng, type IDatabaseEntry, type ISharedSecretEntry } from "user-interface";
import type { IElectronAPI, ISaveAssetItem } from "electron-defs";
import { ProxyVault } from "./proxy-vault";

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

    // Store callbacks for navigate events
    const navigateCallbacksRef = useRef<Set<(page: string) => void>>(new Set());

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

    // Set up message listener for navigate events
    useEffect(() => {
        const handleNavigate = (page: string) => {
            navigateCallbacksRef.current.forEach(cb => cb(page));
        };

        electronAPI.onMessage('navigate', handleNavigate);

        return () => {
            electronAPI.removeAllListeners('navigate');
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

        // Fire opened callbacks so UI components (e.g. recent databases list) refresh.
        openedCallbacksRef.current.forEach(callback => {
            callback(databasePath);
        });
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

    const onNavigate = useCallback((callback: (page: string) => void): (() => void) => {
        navigateCallbacksRef.current.add(callback);
        return () => {
            navigateCallbacksRef.current.delete(callback);
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

    const checkDatabaseExists = useCallback(async (databasePath: string): Promise<boolean> => {
        return await electronAPI.checkDatabaseExists(databasePath);
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

    const getDatabases = useCallback(async (): Promise<IDatabaseEntry[]> => {
        return await electronAPI.getDatabases();
    }, [electronAPI]);

    const addDatabase = useCallback(async (entry: IDatabaseEntry): Promise<IDatabaseEntry> => {
        return await electronAPI.addDatabase(entry);
    }, [electronAPI]);

    const updateDatabase = useCallback(async (entry: IDatabaseEntry): Promise<void> => {
        await electronAPI.updateDatabase(entry);
    }, [electronAPI]);

    const removeDatabaseEntry = useCallback(async (databasePath: string): Promise<void> => {
        await electronAPI.removeDatabaseEntry(databasePath);
    }, [electronAPI]);

    const pickFolder = useCallback(async (): Promise<string | undefined> => {
        return await electronAPI.pickFolder();
    }, [electronAPI]);

    const createDatabaseAtPath = useCallback(async (path: string): Promise<void> => {
        await electronAPI.createDatabaseAtPath(path);
    }, [electronAPI]);

    const listSecrets = useCallback(async (): Promise<ISharedSecretEntry[]> => {
        const vault = new ProxyVault(electronAPI);
        const allSecrets = await vault.list();
        return allSecrets
            .filter(secret => secret.name.startsWith('shared:'))
            .map(secret => {
                const id = secret.name.slice('shared:'.length);
                const parsed = JSON.parse(secret.value);
                return { id, name: parsed.label, type: secret.type };
            });
    }, [electronAPI]);

    const addSecret = useCallback(async (entry: Omit<ISharedSecretEntry, 'id'>, value: string): Promise<ISharedSecretEntry> => {
        const vault = new ProxyVault(electronAPI);
        const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
        let id = '';
        for (let index = 0; index < 8; index++) {
            id += chars[Math.floor(Math.random() * chars.length)];
        }
        const valueWithLabel = JSON.stringify({ label: entry.name, ...JSON.parse(value) });
        await vault.set({ name: `shared:${id}`, type: entry.type, value: valueWithLabel });
        return { id, name: entry.name, type: entry.type };
    }, [electronAPI]);

    const updateSecret = useCallback(async (entry: ISharedSecretEntry, value?: string): Promise<void> => {
        const vault = new ProxyVault(electronAPI);
        if (value !== undefined) {
            const valueWithLabel = JSON.stringify({ label: entry.name, ...JSON.parse(value) });
            await vault.set({ name: `shared:${entry.id}`, type: entry.type, value: valueWithLabel });
        }
        else {
            const existing = await vault.get(`shared:${entry.id}`);
            if (existing) {
                const parsed = JSON.parse(existing.value);
                parsed.label = entry.name;
                await vault.set({ name: `shared:${entry.id}`, type: entry.type, value: JSON.stringify(parsed) });
            }
        }
    }, [electronAPI]);

    const deleteSecret = useCallback(async (id: string): Promise<void> => {
        const vault = new ProxyVault(electronAPI);
        await vault.delete(`shared:${id}`);
    }, [electronAPI]);

    const getSecretValue = useCallback(async (id: string): Promise<string | undefined> => {
        const vault = new ProxyVault(electronAPI);
        const secret = await vault.get(`shared:${id}`);
        return secret?.value;
    }, [electronAPI]);

    const getRecentDatabases = useCallback(async (): Promise<IDatabaseEntry[]> => {
        return await electronAPI.getRecentDatabases();
    }, [electronAPI]);

    const listS3Dirs = useCallback(async (credentialId: string, bucket: string, prefix: string): Promise<string[]> => {
        return await electronAPI.listS3Dirs(credentialId, bucket, prefix);
    }, [electronAPI]);

    const startShareReceive = useCallback(async (): Promise<{ code: string }> => {
        return await electronAPI.startShareReceive();
    }, [electronAPI]);

    const waitShareReceive = useCallback(async (): Promise<unknown> => {
        return await electronAPI.waitShareReceive();
    }, [electronAPI]);

    const cancelShareReceive = useCallback(async (): Promise<void> => {
        await electronAPI.cancelShareReceive();
    }, [electronAPI]);

    const waitForReceiver = useCallback(async (payload: unknown): Promise<unknown> => {
        return await electronAPI.waitForReceiver(payload);
    }, [electronAPI]);

    const sendToReceiver = useCallback(async (endpoint: unknown, code: string): Promise<boolean> => {
        return await electronAPI.sendToReceiver(endpoint, code);
    }, [electronAPI]);

    const cancelShareSend = useCallback(async (): Promise<void> => {
        await electronAPI.cancelShareSend();
    }, [electronAPI]);

    const importSharePayload = useCallback(async (payload: unknown): Promise<void> => {
        await electronAPI.importSharePayload(payload);
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
        onNavigate,
        importAssets,
        getPathForFile,
        checkTools,
        checkDatabaseExists,
        onTaskMessage,
        onTaskComplete,
        cancelTasks,
        getDatabases,
        addDatabase,
        updateDatabase,
        removeDatabaseEntry,
        pickFolder,
        createDatabaseAtPath,
        listSecrets,
        addSecret,
        updateSecret,
        deleteSecret,
        getSecretValue,
        getRecentDatabases,
        listS3Dirs,
        startShareReceive,
        waitShareReceive,
        cancelShareReceive,
        waitForReceiver,
        sendToReceiver,
        cancelShareSend,
        importSharePayload,
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

