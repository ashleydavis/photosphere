import React, { ReactNode, useCallback, useEffect, useRef } from "react";
import { PlatformContextProvider, ConfigContextProvider, createConfig, TEST_MENU_EVENT, TEST_OPEN_DATABASE_EVENT, type IPlatformContext, type IToolsStatus, type IShowNotificationData, type IUpdateAvailableData, type IDatabaseEntry, type ISharedSecretEntry, type IPickFolderOptions } from "user-interface";
import { cancelMobileTasks, subscribeMobileTaskMessage, subscribeMobileTaskComplete } from "./mobile-platform-tasks";

//
// Props for the mobile platform provider.
//
export interface IPlatformProviderMobileProps {
    //
    // Child components that gain access to the platform and config contexts.
    //
    children: ReactNode | ReactNode[];
}

//
// Mobile platform context provider.
// Most native integrations are still stubbed (database, sync, vault, share, file-picker),
// but the background-task bindings (cancelTasks / onTaskMessage / onTaskComplete) are wired
// to the native JsEngine plugin so task-driven UI (notably the Job Manager) works on mobile.
// Config is held in an in-memory Map for the lifetime of the app session.
//
export function PlatformProviderMobile({ children }: IPlatformProviderMobileProps) {
    // In-memory config store. Persists for the lifetime of the app session only.
    const configStoreRef = useRef<Map<string, unknown>>(new Map());

    // Registered callbacks for menu actions and database-opened events. On desktop these fire
    // from native menu / IPC; on mobile (no menu bar) the smoke-test driver drives them via
    // window events (see the useEffect below) so tests exercise the real action handlers.
    const menuActionCallbacksRef = useRef<Set<(action: string) => void>>(new Set());
    const openedCallbacksRef = useRef<Set<(databasePath: string) => void>>(new Set());

    const openDatabase = useCallback(async (): Promise<void> => {
        // No-op: no native database picker on mobile yet.
    }, []);

    const onDatabaseOpened = useCallback((callback: (databasePath: string) => void): (() => void) => {
        openedCallbacksRef.current.add(callback);
        return () => {
            openedCallbacksRef.current.delete(callback);
        };
    }, []);

    const onDatabaseClosed = useCallback((_callback: () => void): (() => void) => {
        return () => {};
    }, []);

    const notifyDatabaseOpened = useCallback(async (_databasePath: string): Promise<void> => {
    }, []);

    const notifyDatabaseClosed = useCallback(async (): Promise<void> => {
    }, []);

    const onThemeChanged = useCallback((_callback: (theme: 'light' | 'dark' | 'system') => void): (() => void) => {
        return () => {};
    }, []);

    const onMenuAction = useCallback((callback: (action: string) => void): (() => void) => {
        menuActionCallbacksRef.current.add(callback);
        return () => {
            menuActionCallbacksRef.current.delete(callback);
        };
    }, []);

    // Bridge the smoke-test driver's window events to the registered callbacks so menu actions
    // and open-database requests drive the real app code paths (which fail where the underlying
    // mobile feature, e.g. storage, is not implemented yet).
    useEffect(() => {
        const handleMenu = (event: Event) => {
            const itemId = (event as CustomEvent<string>).detail;
            menuActionCallbacksRef.current.forEach(callback => callback(itemId));
        };
        const handleOpenDatabase = (event: Event) => {
            const databasePath = (event as CustomEvent<string>).detail;
            openedCallbacksRef.current.forEach(callback => callback(databasePath));
        };
        window.addEventListener(TEST_MENU_EVENT, handleMenu);
        window.addEventListener(TEST_OPEN_DATABASE_EVENT, handleOpenDatabase);
        return () => {
            window.removeEventListener(TEST_MENU_EVENT, handleMenu);
            window.removeEventListener(TEST_OPEN_DATABASE_EVENT, handleOpenDatabase);
        };
    }, []);

    const onNavigate = useCallback((_callback: (page: string) => void): (() => void) => {
        return () => {};
    }, []);

    const notifyDatabaseEdited = useCallback((): void => {
    }, []);

    const copyToClipboard = useCallback(async (_blob: Blob, _contentType: string): Promise<void> => {
        // No-op: native clipboard image support is not wired up on mobile yet.
    }, []);

    const onSyncStarted = useCallback((_callback: () => void): (() => void) => {
        return () => {};
    }, []);

    const onSyncCompleted = useCallback((_callback: () => void): (() => void) => {
        return () => {};
    }, []);

    const onShowNotification = useCallback((_callback: (data: IShowNotificationData) => void): (() => void) => {
        return () => {};
    }, []);

    const onDatabasesChanged = useCallback((_callback: () => void): (() => void) => {
        return () => {};
    }, []);

    const onUpdateAvailable = useCallback((_callback: (data: IUpdateAvailableData) => void): (() => void) => {
        return () => {};
    }, []);

    const openFolder = useCallback(async (_folderPath: string): Promise<void> => {
    }, []);

    const getPathForFile = useCallback((_file: File): string | undefined => {
        return undefined;
    }, []);

    const checkTools = useCallback(async (): Promise<IToolsStatus> => {
        // All tools reported available so tool checks do not block the UI on mobile.
        return {
            magick: { available: true },
            ffprobe: { available: true },
            ffmpeg: { available: true },
            allAvailable: true,
            missingTools: [],
        };
    }, []);

    const checkDatabaseExists = useCallback(async (_databasePath: string): Promise<boolean> => {
        // No database support on mobile yet.
        return false;
    }, []);

    const onTaskMessage = useCallback((handler: (taskId: string, message: Record<string, unknown>) => void): (() => void) => {
        // Subscribe to native taskMessage events streamed by running handlers.
        return subscribeMobileTaskMessage(handler);
    }, []);

    const onTaskComplete = useCallback((handler: (taskId: string, result: Record<string, unknown>) => void): (() => void) => {
        // Subscribe to native taskCompleted events.
        return subscribeMobileTaskComplete(handler);
    }, []);

    const cancelTasks = useCallback(async (sessionId: string): Promise<void> => {
        // Forward cancellation to the native engine (the Job Manager Cancel path).
        await cancelMobileTasks(sessionId);
    }, []);

    const getDatabases = useCallback(async (): Promise<IDatabaseEntry[]> => {
        return [];
    }, []);

    const addDatabase = useCallback(async (entry: IDatabaseEntry): Promise<IDatabaseEntry> => {
        return entry;
    }, []);

    const updateDatabase = useCallback(async (_originalName: string, _entry: IDatabaseEntry): Promise<void> => {
    }, []);

    const setDatabaseOrigin = useCallback(async (_databasePath: string, _origin: string | undefined): Promise<void> => {
    }, []);

    const removeDatabaseEntry = useCallback(async (_name: string): Promise<void> => {
    }, []);

    const findDatabase = useCallback(async (_name: string): Promise<IDatabaseEntry | undefined> => {
        return undefined;
    }, []);

    const pickFolder = useCallback(async (_options?: IPickFolderOptions): Promise<string | undefined> => {
        return undefined;
    }, []);

    const pickFile = useCallback(async (defaultFilename: string): Promise<string | undefined> => {
        return defaultFilename;
    }, []);

    const pickFiles = useCallback(async (_title: string): Promise<string[] | undefined> => {
        return undefined;
    }, []);

    const listSecrets = useCallback(async (): Promise<ISharedSecretEntry[]> => {
        return [];
    }, []);

    const addSecret = useCallback(async (entry: ISharedSecretEntry, _value: string): Promise<ISharedSecretEntry> => {
        return entry;
    }, []);

    const updateSecret = useCallback(async (_originalName: string, _entry: ISharedSecretEntry, _value?: string): Promise<void> => {
    }, []);

    const deleteSecret = useCallback(async (_name: string): Promise<void> => {
    }, []);

    const getSecretValue = useCallback(async (_name: string): Promise<string | undefined> => {
        return undefined;
    }, []);

    const getRecentDatabases = useCallback(async (): Promise<IDatabaseEntry[]> => {
        return [];
    }, []);

    const removeRecentDatabaseName = useCallback(async (_name: string): Promise<void> => {
    }, []);

    const listS3Dirs = useCallback(async (_s3Key: string, _bucket: string, _prefix: string): Promise<string[]> => {
        return [];
    }, []);

    const startShareReceive = useCallback(async (_code: string): Promise<void> => {
    }, []);

    const waitShareReceive = useCallback(async (): Promise<unknown> => {
        return null;
    }, []);

    const cancelShareReceive = useCallback(async (): Promise<void> => {
    }, []);

    const waitForReceiver = useCallback(async (_payload: unknown, _code: string): Promise<unknown> => {
        return null;
    }, []);

    const sendToReceiver = useCallback(async (_endpoint: unknown): Promise<boolean> => {
        return false;
    }, []);

    const cancelShareSend = useCallback(async (): Promise<void> => {
    }, []);

    const importSharePayload = useCallback(async (_payload: unknown, _conflictResolutions: Record<string, unknown>): Promise<void> => {
    }, []);

    const markUpdateAsShown = useCallback(async (_version: string): Promise<void> => {
    }, []);

    const markNewsAsShown = useCallback(async (_newsId: string): Promise<void> => {
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
        copyToClipboard,
        onShowNotification,
        onDatabasesChanged,
        onUpdateAvailable,
        openFolder,
        onMenuAction,
        onNavigate,
        getPathForFile,
        checkTools,
        checkDatabaseExists,
        onTaskMessage,
        onTaskComplete,
        cancelTasks,
        getDatabases,
        addDatabase,
        updateDatabase,
        setDatabaseOrigin,
        removeDatabaseEntry,
        findDatabase,
        pickFolder,
        pickFile,
        pickFiles,
        listSecrets,
        addSecret,
        updateSecret,
        deleteSecret,
        getSecretValue,
        getRecentDatabases,
        removeRecentDatabaseName,
        listS3Dirs,
        startShareReceive,
        waitShareReceive,
        cancelShareReceive,
        waitForReceiver,
        sendToReceiver,
        cancelShareSend,
        importSharePayload,
        markUpdateAsShown,
        markNewsAsShown,
    };

    // In-memory config backed by the session-lifetime Map above.
    const config = createConfig(
        async (key) => configStoreRef.current.get(key),
        async (key, value) => {
            configStoreRef.current.set(key, value);
        }
    );

    return (
        <ConfigContextProvider value={config}>
            <PlatformContextProvider value={platformContext}>
                {children}
            </PlatformContextProvider>
        </ConfigContextProvider>
    );
}
