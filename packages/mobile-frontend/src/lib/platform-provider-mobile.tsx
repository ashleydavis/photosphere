import React, { ReactNode, useCallback, useEffect, useRef } from "react";
import eruda from "eruda";
import { Network } from "@capacitor/network";
import { PlatformContextProvider, ConfigContextProvider, createConfig, useLanShareTasks, readBrowserNetworkStatus, subscribeBrowserNetworkStatus, signalTestAppReady, TEST_MENU_EVENT, TEST_OPEN_DATABASE_EVENT, TEST_SEED_DATABASES_EVENT, TEST_SEED_RECENT_EVENT, TEST_SEED_NEWS_EVENT, TEST_RESET_CONFIG_EVENT, TEST_PICK_FILES_EVENT, TEST_STAGE_EXPORT_EVENT, TEST_STAGE_PICK_FOLDER_EVENT, TEST_SET_SYNC_ALLOWED_EVENT, TEST_NOTIFY_DATABASE_EDITED_EVENT, type ITestResetConfigEventDetail, type IPlatformContext, type IPlatformEvent, type INetworkStatus, type IToolsStatus, type IShowNotificationData, type IUpdateAvailableData, type IDatabaseEntry, type ISharedSecretEntry, type IPickFolderOptions, type ISaveDownloadResult, UuidGeneratorProvider } from "user-interface";
import { TaskQueue, TaskStatus, getQueueBackend } from "task-queue";
import type { ITaskResult } from "task-queue";
import type { ISaveAssetItem } from "api";
import { log, RandomUuidGenerator, TestUuidGenerator, type IUuidGenerator } from "utils";
import { cancelMobileTasks, subscribeMobileTaskMessage, subscribeMobileTaskComplete, pickMobileFiles, setInjectedPickedFiles } from "./mobile-platform-tasks";
import { pickMobileFolder, saveMobileDownloadedFile, saveMobileDownloadedFiles, setInjectedExportOutcome, setInjectedPickFolderResult } from "./mobile-export";
import * as configStore from "./mobile-config-store";
import { MobileSecretStore } from "./mobile-secure-store";
import { createCapacitorSecureStore } from "./secure-store-plugin";
import { importSharePayload as importReceivedShare, type IReceivedSharePayload } from "./mobile-share-receive";
import { MobileSyncScheduler, SYNC_TASK_TYPE } from "./mobile-sync-scheduler";
import type { IConflictResolution } from "lan-share-core";

//
// The uuid generator this platform provides to the app: deterministic under a smoke test so task ids
// are reproducible. On mobile the native layer injects __PHOTOSPHERE_TEST__ into the WebView.
//
const isTestMode = Boolean((globalThis as { __PHOTOSPHERE_TEST__?: boolean }).__PHOTOSPHERE_TEST__);
const uuidGenerator: IUuidGenerator = isTestMode ? new TestUuidGenerator() : new RandomUuidGenerator();

// Whether the in-page Eruda console has been initialised and whether it is currently visible.
let erudaInitialised = false;
let erudaVisible = false;

// Source tag grouping the S3-directory-listing background tasks so they can be cancelled together.
const LIST_S3_DIRS_SOURCE = "list-s3-dirs";

//
// The fields of a completed task result the provider inspects. The native taskCompleted event
// arrives as a plain record, so this names the shape rather than indexing it untyped.
//
interface ICompletedTaskResult {
    // The task type that completed (for example "sync-database").
    type: string;

    // The terminal status of the task.
    status: TaskStatus;
}

//
// The outputs of the list-s3-dirs worker task: the directory names under the requested prefix.
//
interface IListS3DirsOutputs {
    // The immediate subdirectory names under the requested prefix.
    names?: string[];
}

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
// The WebView localStorage used to persist the configured-databases / recent-databases lists and the
// generic config (theme, sync flags). It satisfies the small key/value interface the config store needs.
// Secrets do NOT live here: they are held in the device keychain via secretStore below.
//
const persistentStore: configStore.IKeyValueStore = window.localStorage;

//
// The device keychain every mobile secret is stored in, one item per secret, matching desktop's use of
// the OS keychain. No secret value is cached: each read goes to the keychain and the value is returned
// straight to the caller.
//
const secretStore: MobileSecretStore = new MobileSecretStore(createCapacitorSecureStore());

//
// Deletes the plaintext secrets blob an earlier build wrote to localStorage. Secrets now live in the
// device keychain, so a plaintext copy left on a device by that build is pure exposure with nothing
// reading it. Removed at module load, before any UI can run, and logged so the removal is visible rather
// than silent. Key name only, never a value.
//
if (persistentStore.getItem(configStore.LEGACY_PLAINTEXT_SECRETS_KEY) !== null) {
    persistentStore.removeItem(configStore.LEGACY_PLAINTEXT_SECRETS_KEY);
    log.info(`mobile-secrets: removed the legacy plaintext '${configStore.LEGACY_PLAINTEXT_SECRETS_KEY}' entry from localStorage; secrets are stored in the device keychain and any secret held only in that entry must be re-added.`);
}

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
// Most native integrations are still stubbed (database, sync, file-picker); secrets are not, they are
// stored one item per secret in the device keychain via the SecureStore plugin. The background-task
// bindings (cancelTasks / onTaskMessage / onTaskComplete) are wired
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

    // Registered callbacks for sync-started / sync-completed events. Fired from the worker's sync task
    // messages routed below, mirroring the desktop main process relaying sync-started/sync-completed to
    // the renderer. These drive the navbar sync spinner via the shared SyncContext.
    const syncStartedCallbacksRef = useRef<Set<() => void>>(new Set());
    const syncCompletedCallbacksRef = useRef<Set<() => void>>(new Set());

    // The mobile background-sync scheduler (debounce + periodic + gate), created once. It enqueues
    // sync-database tasks onto the embedded worker queue when the gate permits.
    const syncSchedulerRef = useRef<MobileSyncScheduler | null>(null);
    const getSyncScheduler = useCallback((): MobileSyncScheduler => {
        if (!syncSchedulerRef.current) {
            syncSchedulerRef.current = new MobileSyncScheduler((type, data, source) => {
                getQueueBackend().addTask(type, data, source);
            });
        }
        return syncSchedulerRef.current;
    }, []);

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
        // Point the sync scheduler at the newly opened database and start its periodic timer, so
        // subsequent edits and the periodic interval enqueue syncs for this database.
        const scheduler = getSyncScheduler();
        scheduler.setDatabasePath(databasePath);
        scheduler.start();
    }, [getSyncScheduler]);

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
        // Test setup: seed the recent-databases list.
        const handleSeedRecent = (event: Event) => {
            const databases = (event as CustomEvent<IDatabaseEntry[]>).detail || [];
            configStore.seedRecentDatabases(persistentStore, databases);
        };
        // Test setup: clear all persisted config for a deterministic starting state. Secrets live in the
        // keychain, not localStorage, so they are cleared from the keychain too (resetConfig only removes
        // localStorage keys, which no longer hold any secret).
        const handleResetConfig = (event: Event) => {
            configStore.resetConfig(persistentStore);
            const detail = (event as CustomEvent<ITestResetConfigEventDetail>).detail;
            detail.waitFor(secretStore.clearSecrets());
        };
        // Test setup: stage picked file paths so the next pickFiles resolves with them instead of
        // opening the native picker (which cannot be automated in a smoke test).
        const handlePickFiles = (event: Event) => {
            const paths = (event as CustomEvent<string[]>).detail || [];
            setInjectedPickedFiles(paths);
        };
        // Test setup: stage the outcome of the next asset export (share sheet) so the smoke test drives
        // the shared/cancelled paths without a native sheet that cannot be dismissed on a device.
        const handleStageExport = (event: Event) => {
            const outcome = (event as CustomEvent<"shared" | "cancelled">).detail;
            setInjectedExportOutcome(outcome);
        };
        // Test setup: stage the result of the next pickFolder name prompt (a sandbox-relative path, or
        // null to simulate the user cancelling), so the "Browse" flow needs no native prompt.
        const handleStagePickFolder = (event: Event) => {
            const result = (event as CustomEvent<string | null>).detail ?? null;
            setInjectedPickFolderResult(result);
        };
        // Test setup: open or close the sync gate, so a test can permit an automatic background sync
        // without depending on the device's real network state or the persisted user toggles.
        const handleSetSyncAllowed = (event: Event) => {
            const allowed = (event as CustomEvent<boolean>).detail;
            getSyncScheduler().setSyncAllowed(allowed);
        };
        // Test setup: schedule the debounced background sync, as a real edit through the UI would.
        const handleNotifyDatabaseEdited = () => {
            getSyncScheduler().notifyDatabaseEdited();
        };
        window.addEventListener(TEST_MENU_EVENT, handleMenu);
        window.addEventListener(TEST_OPEN_DATABASE_EVENT, handleOpenDatabase);
        window.addEventListener(TEST_SEED_DATABASES_EVENT, handleSeedDatabases);
        window.addEventListener(TEST_SEED_RECENT_EVENT, handleSeedRecent);
        window.addEventListener(TEST_RESET_CONFIG_EVENT, handleResetConfig);
        window.addEventListener(TEST_PICK_FILES_EVENT, handlePickFiles);
        window.addEventListener(TEST_STAGE_EXPORT_EVENT, handleStageExport);
        window.addEventListener(TEST_STAGE_PICK_FOLDER_EVENT, handleStagePickFolder);
        window.addEventListener(TEST_SET_SYNC_ALLOWED_EVENT, handleSetSyncAllowed);
        window.addEventListener(TEST_NOTIFY_DATABASE_EDITED_EVENT, handleNotifyDatabaseEdited);
        // The test-command listeners are now registered, so it is safe to tell the host bridge the
        // app is ready. Signaling earlier (the WebSocket sends "ready" on connect) let a command
        // fired right after /ready dispatch its one-shot CustomEvent before these listeners existed,
        // dropping it (observed as the create-database dialog never opening under concurrent load).
        signalTestAppReady();
        return () => {
            window.removeEventListener(TEST_MENU_EVENT, handleMenu);
            window.removeEventListener(TEST_OPEN_DATABASE_EVENT, handleOpenDatabase);
            window.removeEventListener(TEST_SEED_DATABASES_EVENT, handleSeedDatabases);
            window.removeEventListener(TEST_SEED_RECENT_EVENT, handleSeedRecent);
            window.removeEventListener(TEST_RESET_CONFIG_EVENT, handleResetConfig);
            window.removeEventListener(TEST_PICK_FILES_EVENT, handlePickFiles);
            window.removeEventListener(TEST_STAGE_EXPORT_EVENT, handleStageExport);
            window.removeEventListener(TEST_STAGE_PICK_FOLDER_EVENT, handleStagePickFolder);
            window.removeEventListener(TEST_SET_SYNC_ALLOWED_EVENT, handleSetSyncAllowed);
            window.removeEventListener(TEST_NOTIFY_DATABASE_EDITED_EVENT, handleNotifyDatabaseEdited);
        };
    }, []);

    const onNavigate = useCallback((_callback: (page: string) => void): (() => void) => {
        return () => {};
    }, []);

    const notifyDatabaseEdited = useCallback((): void => {
        // Debounced background sync after an edit (mirrors desktop's notify-database-edited).
        getSyncScheduler().notifyDatabaseEdited();
    }, [getSyncScheduler]);

    const copyToClipboard = useCallback(async (_blob: Blob, _contentType: string): Promise<void> => {
        // No-op: native clipboard image support is not wired up on mobile yet.
    }, []);

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

    // Route the worker's sync-started / sync-completed task messages to the registered callbacks (which
    // drive the navbar spinner) and settle the scheduler so the next sync can be enqueued. The worker's
    // sync-database handler emits these messages; on mobile there is no main process to relay them, so
    // the provider observes the task-message stream directly.
    useEffect(() => {
        const unsubscribe = subscribeMobileTaskMessage((_taskId, message) => {
            const messageType = (message as { type?: string }).type;
            if (messageType === "sync-started") {
                // Logged at the same point desktop's main process logs it, so both platforms record
                // the sync lifecycle identically and a smoke test can observe the transition from the
                // append-only log rather than racing the transient navbar spinner state.
                log.event("Sync started");
                syncStartedCallbacksRef.current.forEach(callback => callback());
            }
            else if (messageType === "sync-completed") {
                log.event("Sync completed");
                syncCompletedCallbacksRef.current.forEach(callback => callback());
            }
            else if (messageType === "sync-skipped") {
                // A sync that returns early (no origin, origin unreachable) emits no sync-started /
                // sync-completed pair. Logging the worker's reason here is the only place it reaches
                // the app log, so a sync that silently does nothing is diagnosable.
                const reason = (message as { reason?: string }).reason;
                log.event(`Sync skipped: ${reason}`);
            }
        });
        return unsubscribe;
    }, []);

    // Settle the sync scheduler when the sync task itself finishes, mirroring desktop's syncStopped in
    // the task-complete handler. Settling on the sync-completed *message* instead would leave the
    // scheduler stuck believing a sync was still running whenever the sync skipped early or failed,
    // because neither path sends that message, and no later sync would ever be enqueued.
    useEffect(() => {
        const unsubscribe = subscribeMobileTaskComplete((_taskId, result) => {
            const completed = result as unknown as ICompletedTaskResult;
            if (completed.type !== SYNC_TASK_TYPE) {
                return;
            }
            getSyncScheduler().onSyncSettled();
            log.event(`Sync task finished: ${completed.status}`);
            if (completed.status !== TaskStatus.Succeeded) {
                // The spinner was turned on by sync-started but no sync-completed will arrive, so
                // clear it here rather than leaving it spinning forever.
                syncCompletedCallbacksRef.current.forEach(callback => callback());
            }
        });
        return unsubscribe;
    }, [getSyncScheduler]);

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

    const pickFolder = useCallback(async (options?: IPickFolderOptions): Promise<string | undefined> => {
        // A database-path "Browse" prompts for a name. Returns undefined when the user cancels the prompt.
        return pickMobileFolder(options);
    }, []);

    const saveDownloadedFiles = useCallback(async (items: ISaveAssetItem[], databasePath: string): Promise<ISaveDownloadResult> => {
        // Mobile cannot write to a user-chosen location, so the download task writes into app-private
        // storage and the native share sheet then hands the files out, deleting each temp copy on every
        // exit. A cancelled sheet means nothing was handed out.
        const queue = new TaskQueue(uuidGenerator, databasePath);
        let taskResult: ITaskResult | undefined;
        let delivered: boolean;
        if (items.length === 1) {
            delivered = await saveMobileDownloadedFile(items[0].filename, async (destinationPath: string) => {
                const taskId = queue.addTask("save-asset", { assetId: items[0].assetId, assetType: items[0].assetType, destPath: destinationPath, databasePath });
                taskResult = await queue.awaitTask(taskId);
                return taskResult?.status === TaskStatus.Succeeded;
            });
        }
        else {
            delivered = await saveMobileDownloadedFiles(async (destinationFolder: string) => {
                const taskId = queue.addTask("save-assets-batch", { assets: items, folderPath: destinationFolder, databasePath });
                taskResult = await queue.awaitTask(taskId);
                if (taskResult?.status !== TaskStatus.Succeeded) {
                    return undefined;
                }
                const succeeded = (taskResult.outputs as { succeededFiles: string[] }).succeededFiles;
                return succeeded.map(assetFilename => `${destinationFolder}/${assetFilename}`);
            });
        }
        queue.shutdown();

        if (taskResult?.status !== TaskStatus.Succeeded) {
            return { outcome: "failed", savedCount: 0, failedCount: items.length, errorMessage: taskResult?.errorMessage };
        }
        if (!delivered) {
            return { outcome: "cancelled", savedCount: 0, failedCount: 0 };
        }
        if (items.length === 1) {
            return { outcome: "saved", savedCount: 1, failedCount: 0 };
        }
        const outputs = taskResult.outputs as { succeededFiles: string[]; failedFiles: string[] };
        return { outcome: "saved", savedCount: outputs.succeededFiles.length, failedCount: outputs.failedFiles.length };
    }, []);

    const pickFiles = useCallback(async (title: string): Promise<string[] | undefined> => {
        return pickMobileFiles(title);
    }, []);

    const listSecrets = useCallback(async (): Promise<ISharedSecretEntry[]> => {
        return secretStore.listSecrets();
    }, []);

    const addSecret = useCallback(async (entry: ISharedSecretEntry, value: string): Promise<ISharedSecretEntry> => {
        // Resolves only once the keychain write has landed, so the UI reports the secret as added only
        // when it is durable and would survive an immediate app restart.
        return secretStore.addSecret(entry, value);
    }, []);

    const updateSecret = useCallback(async (originalName: string, entry: ISharedSecretEntry, value?: string): Promise<void> => {
        await secretStore.updateSecret(originalName, entry, value);
    }, []);

    const deleteSecret = useCallback(async (name: string): Promise<void> => {
        await secretStore.deleteSecret(name);
    }, []);

    const getSecretValue = useCallback(async (name: string): Promise<string | undefined> => {
        return secretStore.getSecretValue(name);
    }, []);

    const getRecentDatabases = useCallback(async (): Promise<IDatabaseEntry[]> => {
        return configStore.getRecentDatabases(persistentStore);
    }, []);

    const removeRecentDatabaseName = useCallback(async (name: string): Promise<void> => {
        configStore.removeRecentDatabase(persistentStore, name);
        // Matches the desktop main process so smoke tests observe the same log line.
        log.info(`Recent database removed: ${name}`);
    }, []);

    const listS3Dirs = useCallback(async (s3Key: string, bucket: string, prefix: string): Promise<string[]> => {
        // The WebView has no S3 client or vault access, so list directories via a background task on the
        // embedded worker (which has both). A failure (bad credentials, unreachable bucket) rejects here,
        // so the S3 browser shows a real error rather than the empty-array stub's fake empty bucket.
        const queue = new TaskQueue(new RandomUuidGenerator(), LIST_S3_DIRS_SOURCE);
        try {
            const taskId = queue.addTask("list-s3-dirs", { s3Key, bucket, prefix });
            const result = await queue.awaitTask(taskId);
            if (!result || result.status === TaskStatus.Failed) {
                throw new Error(result?.errorMessage || "Failed to list S3 directories");
            }
            const outputs = result.outputs as IListS3DirsOutputs;
            return outputs?.names ?? [];
        }
        finally {
            queue.shutdown();
        }
    }, []);

    const importSharePayload = useCallback(async (payload: unknown, conflictResolutions: Record<string, unknown>): Promise<void> => {
        // Imports a LAN-received database (into the config store) or secret (into the device keychain
        // via secretStore, per step 6b); see mobile-share-receive.ts.
        await importReceivedShare(persistentStore, secretStore, payload as IReceivedSharePayload, conflictResolutions as Record<string, IConflictResolution>);
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
    // Pushes the shared sync gate's decision to the scheduler. When sync becomes allowed the scheduler
    // schedules a catch-up sync; when disallowed it cancels any pending debounce, so no automatic sync
    // is enqueued while the gate is closed (matches desktop's set-sync-allowed behaviour).
    //
    const setSyncAllowed = useCallback((allowed: boolean): void => {
        getSyncScheduler().setSyncAllowed(allowed);
    }, [getSyncScheduler]);

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
        saveDownloadedFiles,
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
        <UuidGeneratorProvider value={uuidGenerator}>
            <ConfigContextProvider value={config}>
                <PlatformContextProvider value={platformContext}>
                    {children}
                </PlatformContextProvider>
            </ConfigContextProvider>
        </UuidGeneratorProvider>
    );
}
