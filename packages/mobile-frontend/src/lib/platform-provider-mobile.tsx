import React, { ReactNode, useCallback, useEffect, useRef } from "react";
import { PlatformContextProvider, ConfigContextProvider, createConfig, TEST_MENU_EVENT, TEST_OPEN_DATABASE_EVENT, TEST_SEED_DATABASES_EVENT, TEST_SEED_SECRETS_EVENT, TEST_SEED_RECENT_EVENT, TEST_SEED_NEWS_EVENT, TEST_RESET_CONFIG_EVENT, type IPlatformContext, type IToolsStatus, type IShowNotificationData, type IUpdateAvailableData, type IDatabaseEntry, type ISharedSecretEntry, type IPickFolderOptions } from "user-interface";
import { log } from "utils";
import { cancelMobileTasks, subscribeMobileTaskMessage, subscribeMobileTaskComplete } from "./mobile-platform-tasks";
import * as configStore from "./mobile-config-store";

//
// The WebView localStorage used to persist the configured-databases / recent-databases lists. It
// satisfies the small key/value interface the config store needs.
//
const persistentStore: configStore.IKeyValueStore = window.localStorage;

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
// Generic config is persisted to WebView localStorage so settings survive app restarts.
//
export function PlatformProviderMobile({ children }: IPlatformProviderMobileProps) {
    // Registered callbacks for menu actions and database-opened events. On desktop these fire
    // from native menu / IPC; on mobile (no menu bar) the smoke-test driver drives them via
    // window events (see the useEffect below) so tests exercise the real action handlers.
    const menuActionCallbacksRef = useRef<Set<(action: string) => void>>(new Set());
    const openedCallbacksRef = useRef<Set<(databasePath: string) => void>>(new Set());

    // Registered callbacks for show-notification events (used by the news-notification flow).
    const showNotificationCallbacksRef = useRef<Set<(data: IShowNotificationData) => void>>(new Set());

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

    const notifyDatabaseOpened = useCallback(async (databasePath: string): Promise<void> => {
        // Record the opened database as most-recent (look up its registered name, else use the path's
        // final segment) and log a line matching the desktop main process so smoke tests observe it.
        const known = configStore.findDatabaseByPath(persistentStore, databasePath);
        const name = known?.name ?? configStore.databaseBasename(databasePath);
        configStore.addRecentDatabase(persistentStore, known ?? { name, description: "", path: databasePath });
        log.info(`Database opened: ${configStore.databaseBasename(databasePath)}`);
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
        // Test setup: seed the configured-databases list (mirrors desktop seeding databases.toml).
        const handleSeedDatabases = (event: Event) => {
            const databases = (event as CustomEvent<IDatabaseEntry[]>).detail || [];
            configStore.seedDatabases(persistentStore, databases);
        };
        // Test setup: seed the secrets list (mirrors desktop seeding the vault).
        const handleSeedSecrets = (event: Event) => {
            const secrets = (event as CustomEvent<configStore.IStoredSecret[]>).detail || [];
            configStore.seedSecrets(persistentStore, secrets);
        };
        // Test setup: seed the recent-databases list.
        const handleSeedRecent = (event: Event) => {
            const databases = (event as CustomEvent<IDatabaseEntry[]>).detail || [];
            configStore.seedRecentDatabases(persistentStore, databases);
        };
        // Test setup: clear all persisted config for a deterministic starting state.
        const handleResetConfig = () => {
            configStore.resetConfig(persistentStore);
        };
        window.addEventListener(TEST_MENU_EVENT, handleMenu);
        window.addEventListener(TEST_OPEN_DATABASE_EVENT, handleOpenDatabase);
        window.addEventListener(TEST_SEED_DATABASES_EVENT, handleSeedDatabases);
        window.addEventListener(TEST_SEED_SECRETS_EVENT, handleSeedSecrets);
        window.addEventListener(TEST_SEED_RECENT_EVENT, handleSeedRecent);
        window.addEventListener(TEST_RESET_CONFIG_EVENT, handleResetConfig);
        return () => {
            window.removeEventListener(TEST_MENU_EVENT, handleMenu);
            window.removeEventListener(TEST_OPEN_DATABASE_EVENT, handleOpenDatabase);
            window.removeEventListener(TEST_SEED_DATABASES_EVENT, handleSeedDatabases);
            window.removeEventListener(TEST_SEED_SECRETS_EVENT, handleSeedSecrets);
            window.removeEventListener(TEST_SEED_RECENT_EVENT, handleSeedRecent);
            window.removeEventListener(TEST_RESET_CONFIG_EVENT, handleResetConfig);
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

    const onShowNotification = useCallback((callback: (data: IShowNotificationData) => void): (() => void) => {
        showNotificationCallbacksRef.current.add(callback);
        return () => {
            showNotificationCallbacksRef.current.delete(callback);
        };
    }, []);

    // Shows the first not-yet-shown news item as a toast (fires the show-notification callbacks) and
    // logs a line matching the desktop main process so smoke tests observe it. No-op when there is no
    // unshown news. News items are seeded in tests; production news fetching is a later layer.
    const showFirstUnshownNews = useCallback((): void => {
        const item = configStore.firstUnshownNews(persistentStore);
        if (!item) {
            return;
        }
        const data: IShowNotificationData = configStore.buildNewsNotification(item);
        showNotificationCallbacksRef.current.forEach(callback => callback(data));
        log.info(`Showed news notification: ${item.id}`);
    }, []);

    // News notifications: show any unshown news on startup, and (in tests) when news is seeded. The
    // show-notification callbacks are registered by the app's notification effect, which runs before
    // this parent effect, so they are in place when showFirstUnshownNews fires.
    useEffect(() => {
        const handleSeedNews = (event: Event) => {
            const items = (event as CustomEvent<configStore.INewsItemRecord[]>).detail || [];
            configStore.seedNews(persistentStore, items);
            showFirstUnshownNews();
        };
        window.addEventListener(TEST_SEED_NEWS_EVENT, handleSeedNews);
        showFirstUnshownNews();
        return () => {
            window.removeEventListener(TEST_SEED_NEWS_EVENT, handleSeedNews);
        };
    }, [showFirstUnshownNews]);

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
        // The WebView has no filesystem access, so existence cannot be checked here directly. Treat
        // the database as present and let the load-assets task surface a genuinely missing/corrupt
        // database as a task error. (A precise check would need a native fs call from the WebView.)
        return true;
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
        return configStore.getDatabases(persistentStore);
    }, []);

    const addDatabase = useCallback(async (entry: IDatabaseEntry): Promise<IDatabaseEntry> => {
        const added = configStore.addDatabase(persistentStore, entry);
        // Matches the desktop main process so smoke tests observe the same log line.
        log.info("Database entry added");
        return added;
    }, []);

    const updateDatabase = useCallback(async (originalName: string, entry: IDatabaseEntry): Promise<void> => {
        configStore.updateDatabase(persistentStore, originalName, entry);
    }, []);

    const setDatabaseOrigin = useCallback(async (databasePath: string, origin: string | undefined): Promise<void> => {
        configStore.setDatabaseOrigin(persistentStore, databasePath, origin);
    }, []);

    const removeDatabaseEntry = useCallback(async (name: string): Promise<void> => {
        configStore.removeDatabase(persistentStore, name);
    }, []);

    const findDatabase = useCallback(async (name: string): Promise<IDatabaseEntry | undefined> => {
        return configStore.findDatabase(persistentStore, name);
    }, []);

    const pickFolder = useCallback(async (_options?: IPickFolderOptions): Promise<string | undefined> => {
        // No native folder picker yet; downloads go to a fixed sandbox-relative "downloads" folder.
        return "downloads";
    }, []);

    const pickFile = useCallback(async (defaultFilename: string): Promise<string | undefined> => {
        return defaultFilename;
    }, []);

    const pickFiles = useCallback(async (_title: string): Promise<string[] | undefined> => {
        return undefined;
    }, []);

    const listSecrets = useCallback(async (): Promise<ISharedSecretEntry[]> => {
        return configStore.listSecrets(persistentStore);
    }, []);

    const addSecret = useCallback(async (entry: ISharedSecretEntry, value: string): Promise<ISharedSecretEntry> => {
        return configStore.addSecret(persistentStore, entry, value);
    }, []);

    const updateSecret = useCallback(async (originalName: string, entry: ISharedSecretEntry, value?: string): Promise<void> => {
        configStore.updateSecret(persistentStore, originalName, entry, value);
    }, []);

    const deleteSecret = useCallback(async (name: string): Promise<void> => {
        configStore.deleteSecret(persistentStore, name);
    }, []);

    const getSecretValue = useCallback(async (name: string): Promise<string | undefined> => {
        return configStore.getSecretValue(persistentStore, name);
    }, []);

    const getRecentDatabases = useCallback(async (): Promise<IDatabaseEntry[]> => {
        return configStore.getRecentDatabases(persistentStore);
    }, []);

    const removeRecentDatabaseName = useCallback(async (name: string): Promise<void> => {
        configStore.removeRecentDatabase(persistentStore, name);
        // Matches the desktop main process so smoke tests observe the same log line.
        log.info(`Recent database removed: ${name}`);
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

    const markNewsAsShown = useCallback(async (newsId: string): Promise<void> => {
        configStore.addShownNewsId(persistentStore, newsId);
        // Matches the desktop main process so smoke tests observe the same log line.
        log.info(`Marked news notification as shown: ${newsId}`);
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

    // Generic config persisted to WebView localStorage so settings (developer mode, theme, etc.)
    // survive app restarts, matching how databases and secrets are persisted.
    const config = createConfig(
        async (key) => configStore.getConfigValue(persistentStore, key),
        async (key, value) => {
            configStore.setConfigValue(persistentStore, key, value);
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
