import React, { ReactNode, useCallback, useEffect, useRef } from "react";
import eruda from "eruda";
import { Network } from "@capacitor/network";
import { PlatformContextProvider, ConfigContextProvider, createConfig, useLanShareTasks, readBrowserNetworkStatus, subscribeBrowserNetworkStatus, signalTestAppReady, TEST_MENU_EVENT, TEST_OPEN_DATABASE_EVENT, TEST_SEED_DATABASES_EVENT, TEST_SEED_SECRETS_EVENT, TEST_SEED_RECENT_EVENT, TEST_SEED_NEWS_EVENT, TEST_RESET_CONFIG_EVENT, TEST_PICK_FILES_EVENT, type IPlatformContext, type IPlatformEvent, type INetworkStatus, type IToolsStatus, type IShowNotificationData, type IUpdateAvailableData, type IDatabaseEntry, type ISharedSecretEntry, type IPickFolderOptions } from "user-interface";
import { log } from "utils";
import { cancelMobileTasks, subscribeMobileTaskMessage, subscribeMobileTaskComplete, pickMobileFiles, setInjectedPickedFiles } from "./mobile-platform-tasks";
import * as configStore from "./mobile-config-store";
import { logSyncGate } from "./sync-gate-log";

// Whether the in-page Eruda console has been initialised and whether it is currently visible.
let erudaInitialised = false;
let erudaVisible = false;

// The last sync-gate decision pushed by the shared SyncContext. Mobile has no
// sync scheduler yet, so this is retained for a future mobile scheduler to read.
let lastSyncAllowed = false;

//
// Shows or hides the in-page Eruda developer console, the only inspector
// reachable from inside the WebView on a physical mobile device.
//
function toggleEruda(): void {
    if (!erudaInitialised) {
        eruda.init();
        erudaInitialised = true;
    }
    if (erudaVisible) {
        eruda.hide();
    }
    else {
        eruda.show();
    }
    erudaVisible = !erudaVisible;
}

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
// Most native integrations are still stubbed (database, sync, vault, file-picker),
// but the background-task bindings (cancelTasks / onTaskMessage / onTaskComplete) are wired
// to the native JsEngine plugin so task-driven UI (notably the Job Manager) works on mobile.
// Share/receive now run as background tasks via useLanShareTasks; these fail at runtime on
// the embedded JS engine until native networking host functions exist.
// Generic config is persisted to WebView localStorage so settings survive app restarts.
//
export function PlatformProviderMobile({ children }: IPlatformProviderMobileProps) {
    // LAN database-sharing methods, dispatched through the shared task queue.
    const { startShareReceive, waitShareReceive, cancelShareReceive, waitForReceiver, sendToReceiver, cancelShareSend } = useLanShareTasks();

    // Registered callbacks for menu actions and database-opened events. On desktop these fire
    // from native menu / IPC; on mobile (no menu bar) the smoke-test driver drives them via
    // window events (see the useEffect below) so tests exercise the real action handlers.
    const platformEventCallbacksRef = useRef<Set<(event: IPlatformEvent) => void>>(new Set());
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

    const onPlatformEvent = useCallback((callback: (event: IPlatformEvent) => void): (() => void) => {
        platformEventCallbacksRef.current.add(callback);
        return () => {
            platformEventCallbacksRef.current.delete(callback);
        };
    }, []);

    // Bridge the smoke-test driver's window events to the registered callbacks so menu actions
    // and open-database requests drive the real app code paths (which fail where the underlying
    // mobile feature, e.g. storage, is not implemented yet).
    useEffect(() => {
        const handleMenu = (event: Event) => {
            const itemId = (event as CustomEvent<string>).detail;
            platformEventCallbacksRef.current.forEach(callback => callback({ type: "menu-action", action: itemId }));
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
        // Test setup: stage picked file paths so the next pickFiles resolves with them instead of
        // opening the native picker (which cannot be automated in a smoke test).
        const handlePickFiles = (event: Event) => {
            const paths = (event as CustomEvent<string[]>).detail || [];
            setInjectedPickedFiles(paths);
        };
        window.addEventListener(TEST_MENU_EVENT, handleMenu);
        window.addEventListener(TEST_OPEN_DATABASE_EVENT, handleOpenDatabase);
        window.addEventListener(TEST_SEED_DATABASES_EVENT, handleSeedDatabases);
        window.addEventListener(TEST_SEED_SECRETS_EVENT, handleSeedSecrets);
        window.addEventListener(TEST_SEED_RECENT_EVENT, handleSeedRecent);
        window.addEventListener(TEST_RESET_CONFIG_EVENT, handleResetConfig);
        window.addEventListener(TEST_PICK_FILES_EVENT, handlePickFiles);
        // The test-command listeners are now registered, so it is safe to tell the host bridge the
        // app is ready. Signaling earlier (the WebSocket sends "ready" on connect) let a command
        // fired right after /ready dispatch its one-shot CustomEvent before these listeners existed,
        // dropping it (observed as the create-database dialog never opening under concurrent load).
        signalTestAppReady();
        return () => {
            window.removeEventListener(TEST_MENU_EVENT, handleMenu);
            window.removeEventListener(TEST_OPEN_DATABASE_EVENT, handleOpenDatabase);
            window.removeEventListener(TEST_SEED_DATABASES_EVENT, handleSeedDatabases);
            window.removeEventListener(TEST_SEED_SECRETS_EVENT, handleSeedSecrets);
            window.removeEventListener(TEST_SEED_RECENT_EVENT, handleSeedRecent);
            window.removeEventListener(TEST_RESET_CONFIG_EVENT, handleResetConfig);
            window.removeEventListener(TEST_PICK_FILES_EVENT, handlePickFiles);
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
        // magick/ffprobe/ffmpeg are bundled natively in the mobile apps (in-process ImageMagick and
        // ffmpeg reached through the host bridge), so they are genuinely available and reported as such.
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

    const pickFiles = useCallback(async (title: string): Promise<string[] | undefined> => {
        return pickMobileFiles(title);
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

    const importSharePayload = useCallback(async (_payload: unknown, _conflictResolutions: Record<string, unknown>): Promise<void> => {
    }, []);

    const markUpdateAsShown = useCallback(async (_version: string): Promise<void> => {
    }, []);

    const markNewsAsShown = useCallback(async (newsId: string): Promise<void> => {
        configStore.addShownNewsId(persistentStore, newsId);
        // Matches the desktop main process so smoke tests observe the same log line.
        log.info(`Marked news notification as shown: ${newsId}`);
    }, []);

    //
    // Toggles the in-page Eruda console; mobile has no native in-app inspector.
    //
    const toggleDevTools = useCallback((): void => {
        toggleEruda();
    }, []);

    //
    // Reports online state and connection type. Tries the WebView's Network
    // Information API first; when it is inconclusive (connectionType "unknown",
    // e.g. on iOS WKWebView which does not expose `type`), falls back to the
    // native @capacitor/network plugin, which reports the real type on both iOS
    // and Android.
    //
    const getNetworkStatus = useCallback(async (): Promise<INetworkStatus> => {
        const browserStatus = readBrowserNetworkStatus();
        if (browserStatus.connectionType !== "unknown") {
            return browserStatus;
        }
        const nativeStatus = await Network.getStatus();
        return { connected: nativeStatus.connected, connectionType: nativeStatus.connectionType };
    }, []);

    //
    // Fires the callback when the connection changes, from either the browser
    // events or the native plugin listener. Each change re-resolves the best
    // available status (browser first, native fallback). Returns an unsubscribe.
    //
    const onNetworkStatusChange = useCallback((callback: (status: INetworkStatus) => void): (() => void) => {
        let cancelled = false;
        const emit = () => {
            getNetworkStatus().then(status => {
                if (!cancelled) {
                    callback(status);
                }
            });
        };
        const unsubscribeBrowser = subscribeBrowserNetworkStatus(() => emit());
        const nativeHandle = Network.addListener("networkStatusChange", () => emit());
        return () => {
            cancelled = true;
            unsubscribeBrowser();
            nativeHandle.then(handle => handle.remove());
        };
    }, [getNetworkStatus]);

    //
    // Stores the shared sync gate's decision. Mobile has no sync scheduler yet,
    // so the value is retained for a future mobile scheduler to honour.
    // Matches the desktop main-process log so smoke tests observe the same line.
    //
    const setSyncAllowed = useCallback((allowed: boolean): void => {
        lastSyncAllowed = allowed;
        logSyncGate(allowed);
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
        onPlatformEvent,
        onNavigate,
        getPathForFile,
        supportsDragAndDropImport: false,
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
        toggleDevTools,
        getNetworkStatus,
        onNetworkStatusChange,
        setSyncAllowed,
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
