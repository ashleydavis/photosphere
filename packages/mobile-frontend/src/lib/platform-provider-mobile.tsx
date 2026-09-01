import React, { ReactNode, useCallback, useEffect, useRef } from "react";
import eruda from "eruda";
import { Capacitor } from "@capacitor/core";
import { Network } from "@capacitor/network";
import { PlatformContextProvider, ConfigContextProvider, createConfig, useLanShareTasks, readBrowserNetworkStatus, subscribeBrowserNetworkStatus, signalTestAppReady, TEST_MENU_EVENT, TEST_OPEN_DATABASE_EVENT, TEST_SEED_NEWS_EVENT, TEST_PICK_FILES_EVENT, TEST_STAGE_EXPORT_EVENT, TEST_STAGE_DELETE_EVENT, TEST_STAGE_PICK_FOLDER_EVENT, TEST_NOTIFY_DATABASE_EDITED_EVENT, type IPlatformContext, type IPlatformEvent, type INetworkStatus, type IToolsStatus, type IShowNotificationData, type IUpdateAvailableData, type IDatabaseEntry, type ISharedSecretEntry, type IPickFolderOptions, type ISaveDownloadResult, UuidGeneratorProvider } from "user-interface";
import { TaskQueue, TaskStatus, getQueueBackend } from "task-queue";
import type { ITaskResult } from "task-queue";
import type { ISaveAssetItem } from "api";
import { log, RandomUuidGenerator, TestUuidGenerator, type IUuidGenerator } from "utils";
import { cancelMobileTasks, subscribeMobileTaskMessage, subscribeMobileTaskComplete, pickMobileFiles, setInjectedPickedFiles } from "./mobile-platform-tasks";
import { pickMobileFolder, saveMobileDownloadedFile, saveMobileDownloadedFiles, setInjectedExportOutcome, setInjectedPickFolderResult } from "./mobile-export";
import { setInjectedDeleteOutcome } from "./mobile-media-cleanup";
import { AUTO_IMPORT_ENABLED_KEY } from "user-interface";
import type { IImportProgressMessage, IImportTimingsMessage } from "api/src/lib/import-assets.types";
import { formatImportTimings } from "node-api/src/lib/import-timings";
import type { IAutoImportSource } from "api/src/lib/auto-import-settings";
import { planMobileAutoImport } from "api/src/lib/auto-import-mobile";
import { getAutoImportFileValue, isAutoImportFileKey, readAutoImportFile, setAutoImportFileValue } from "./mobile-auto-import-file";
import { mobileAutoImportConfigFile } from "./mobile-auto-import-config-file";
import { getSyncFileValue, isSyncFileKey, seedSyncSettingsFile, setSyncFileValue } from "./mobile-sync-file";
import { mobileSyncConfigFile } from "./mobile-sync-config-file";
import { readPermissionState, resolveMediaPermission } from "./mobile-media-permission";
import { JsEngine } from "./js-engine-plugin";
import * as configStore from "./mobile-config-store";
import { MobileSecretStore } from "./mobile-secure-store";
import { createCapacitorSecureStore } from "./secure-store-plugin";
import { importSharePayload as importReceivedShare, type IReceivedSharePayload } from "./mobile-share-receive";
import { shouldSyncAfterEdit, SYNC_AFTER_EDIT_DELAY_MS, SYNC_TASK_TYPE } from "./mobile-edit-sync";
import { mobileDatabasesConfigFile } from "./mobile-databases-config-file";
import { LAST_DATABASE_KEY } from "user-interface/src/lib/last-database-config";
import type { IConflictResolution } from "lan-share-core";

//
// The uuid generator this platform provides to the app: deterministic under a smoke test so task ids
// are reproducible. On mobile the native layer injects __PHOTOSPHERE_TEST__ into the WebView.
//
//
// What automatic import does on this phone while the app is not on screen.
//
// The two platforms differ, and the difference is the platform rather than a design choice, so the
// card says which one the user has. Android runs a foreground service and keeps importing with the
// screen off. iOS runs a background processing task the system schedules when it chooses, typically
// while the phone is charging and idle, so a phone in a pocket all day may import nothing until the
// app is opened. Saying "keeps backing up" on iOS would be a promise the platform does not keep.
//
const BACKGROUND_IMPORT_DESCRIPTION = Capacitor.getPlatform() === "ios"
    ? "When the app is not open, iOS decides when to catch up, usually while the phone is charging."
    : "Keeps importing when the app is closed and the screen is off, showing a notification while it does.";

const isTestMode = Boolean((globalThis as { __PHOTOSPHERE_TEST__?: boolean }).__PHOTOSPHERE_TEST__);
const uuidGenerator: IUuidGenerator = isTestMode ? new TestUuidGenerator() : new RandomUuidGenerator();

// Whether the in-page Eruda console has been initialised and whether it is currently visible.
let erudaInitialised = false;
let erudaVisible = false;

// Source tag identifying an S3-directory-listing background task. Every listing shares it.
//
// This used to be a prefix with a fresh id appended per listing, to work around the engine pool
// never un-cancelling a source: each listing shuts its queue down when it finishes, that shutdown
// cancelled the source, and with one fixed tag every listing after the first was dropped before
// dispatch, leaving the S3 browser showing an empty bucket with no error. The pool now re-arms a
// source when a task is queued from the WebView, so a stable tag is correct again.
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
// The background-task bindings (cancelTasks / onTaskMessage / onTaskComplete) are wired
// to the native JsEngine plugin so task-driven UI (notably the Job Manager) works on mobile.
// The vault (all five secret methods, stored one item per secret in the device keychain via the
// SecureStore plugin) and the file-picker (pickFiles reaches the real native picker) are
// implemented, not stubbed. Share/receive run as background tasks via useLanShareTasks,
// dispatched to the embedded JS engine, where the native networking host functions (TcpHost,
// UdpHost, TlsHost) back them. openDatabase remains a no-op: there is no native database picker
// on mobile yet.
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

    // Registered callbacks for the open database having changed while the WebView was not running.
    const databaseContentChangedCallbacksRef = useRef<Set<() => void>>(new Set());

    // Registered callbacks for sync-started / sync-completed events. Fired from the worker's sync task
    // messages routed below, mirroring the desktop main process relaying sync-started/sync-completed to
    // the renderer. These drive the navbar sync spinner via the shared SyncContext.
    const syncStartedCallbacksRef = useRef<Set<() => void>>(new Set());
    const syncCompletedCallbacksRef = useRef<Set<() => void>>(new Set());

    // Whether this provider has told the native side to start the background import, so a settings
    // write that changes nothing about it does not start it again.
    const autoImportStartedRef = useRef<boolean>(false);

    // Called when one of the automatic import settings is written, so the background import is told
    // to start or stop straight away rather than finding out later.
    const autoImportChangedRef = useRef<(() => void) | undefined>(undefined);

    // Whether an automatic sync is currently permitted, pushed in by the sync context. The native
    // loop asks the same question for itself, through the plan-sync task; this copy is only for the
    // edit-triggered sync below, which the native loop cannot make.
    const syncAllowedRef = useRef<boolean>(false);

    // The path of the open database, or undefined when none is open. This is the database an edit
    // syncs, which is not necessarily the one the background loop pushes: that one is whichever
    // automatic import writes to.
    const openDatabasePathRef = useRef<string | undefined>(undefined);

    // Whether a sync started by an edit is still running, so a second edit does not queue a sync
    // behind the first one holding an engine slot.
    const syncInFlightRef = useRef<boolean>(false);

    // The pending wait between the last edit and the sync it starts, or undefined when none is
    // waiting. Reset by every edit, so a run of them coalesces into one sync.
    const syncAfterEditTimerRef = useRef<NodeJS.Timeout | undefined>(undefined);

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
        const known = await configStore.findDatabaseByPath(mobileDatabasesConfigFile, databasePath);
        const name = known?.name ?? configStore.databaseBasename(databasePath);
        await configStore.addRecentDatabase(mobileDatabasesConfigFile, known ?? { name, description: "", path: databasePath });
        log.info(`Database opened: ${configStore.databaseBasename(databasePath)}`);
        // Remember which database an edit made from here syncs. Nothing periodic starts with it: the
        // loop that syncs on its own lives on the native side and pushes the database automatic
        // import writes to, whether or not this one is open.
        openDatabasePathRef.current = databasePath;
        // Notify the database-opened subscribers (the app-context reload and the sidebar's recent-database
        // refresh). This is the real production trigger; TEST_OPEN_DATABASE_EVENT is the test-only path.
        openedCallbacksRef.current.forEach(callback => callback(databasePath));
    }, []);

    const notifyDatabaseClosed = useCallback(async (): Promise<void> => {
        // Nothing is open, so an edit has nothing to sync. Cleared rather than left, because a stale
        // path here would queue a sync for a database the app has closed.
        openDatabasePathRef.current = undefined;
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
        // Test setup: stage the answer to the next photo library delete request, so the smoke test
        // drives both the confirmed and the declined path without the system confirmation, which no
        // automated test can tap. Everything above the dialog stays real.
        const handleStageDelete = (event: Event) => {
            const outcome = (event as CustomEvent<"deleted" | "cancelled">).detail;
            setInjectedDeleteOutcome(outcome)
                .catch(error => log.exception("Failed to stage the delete outcome", error as Error));
        };
        // Test setup: stage the result of the next pickFolder name prompt (a sandbox-relative path, or
        // null to simulate the user cancelling), so the "Browse" flow needs no native prompt.
        const handleStagePickFolder = (event: Event) => {
            const result = (event as CustomEvent<string | null>).detail ?? null;
            setInjectedPickFolderResult(result);
        };
        // Test setup: start the sync an edit through the UI would start. The same function the
        // interface calls, so what a test exercises is the real path and not a copy of it.
        const handleNotifyDatabaseEdited = () => {
            notifyDatabaseEdited();
        };
        window.addEventListener(TEST_MENU_EVENT, handleMenu);
        window.addEventListener(TEST_OPEN_DATABASE_EVENT, handleOpenDatabase);
        window.addEventListener(TEST_PICK_FILES_EVENT, handlePickFiles);
        window.addEventListener(TEST_STAGE_EXPORT_EVENT, handleStageExport);
        window.addEventListener(TEST_STAGE_DELETE_EVENT, handleStageDelete);
        window.addEventListener(TEST_STAGE_PICK_FOLDER_EVENT, handleStagePickFolder);
        window.addEventListener(TEST_NOTIFY_DATABASE_EDITED_EVENT, handleNotifyDatabaseEdited);
        // The test-command listeners are now registered, so it is safe to tell the host bridge the
        // app is ready. Signaling earlier (the WebSocket sends "ready" on connect) let a command
        // fired right after /ready dispatch its one-shot CustomEvent before these listeners existed,
        // dropping it (observed as the create-database dialog never opening under concurrent load).
        signalTestAppReady();
        return () => {
            window.removeEventListener(TEST_MENU_EVENT, handleMenu);
            window.removeEventListener(TEST_OPEN_DATABASE_EVENT, handleOpenDatabase);
            window.removeEventListener(TEST_PICK_FILES_EVENT, handlePickFiles);
            window.removeEventListener(TEST_STAGE_EXPORT_EVENT, handleStageExport);
            window.removeEventListener(TEST_STAGE_DELETE_EVENT, handleStageDelete);
            window.removeEventListener(TEST_STAGE_PICK_FOLDER_EVENT, handleStagePickFolder);
            window.removeEventListener(TEST_NOTIFY_DATABASE_EDITED_EVENT, handleNotifyDatabaseEdited);
        };
    }, []);

    const notifyDatabaseEdited = useCallback((): void => {
        // One sync for the database the edit was made in, a few seconds after the edits stop.
        //
        // Nothing periodic hangs off this: the loop that syncs on its own runs natively and pushes
        // the database automatic import writes to, which is not necessarily the one on screen. This
        // is what gets an edit to a database the user opened by hand out to its origin.
        //
        // The wait is what makes it one sync rather than a stream of them. An import announces every
        // operation it persists, so starting on the first announcement runs a sync beside the import
        // still making them, and each sync opens the origin's storage. It also keeps the enqueue out
        // of this caller's stack: this runs inside the code persisting the edit, and a failure to
        // queue a sync must not surface as the edit failing.
        if (syncAfterEditTimerRef.current !== undefined) {
            clearTimeout(syncAfterEditTimerRef.current);
        }

        syncAfterEditTimerRef.current = setTimeout(() => {
            syncAfterEditTimerRef.current = undefined;

            if (!shouldSyncAfterEdit({
                syncAllowed: syncAllowedRef.current,
                databasePath: openDatabasePathRef.current,
                syncInFlight: syncInFlightRef.current,
            })) {
                return;
            }

            const databasePath = openDatabasePathRef.current!;
            syncInFlightRef.current = true;
            getQueueBackend().addTask(SYNC_TASK_TYPE, { databasePath }, databasePath);
        }, SYNC_AFTER_EDIT_DELAY_MS);
    }, []);

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
                // The suffix says whether the sync moved anything, which is the only way to tell a
                // sync that ran and found both sides identical from one that pushed changes. Keep
                // "Sync completed" as the start of the line: the smoke tests that predate this wait on
                // that substring alone (wait_for_log matches by substring), so they keep passing
                // untouched. Do not "tidy" the prefix away.
                const synced = (message as { synced?: boolean }).synced;
                log.event(synced ? "Sync completed: changes synced" : "Sync completed: nothing to sync");
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

    // Let the next edit start a sync once this one's task has finished, mirroring desktop's
    // syncStopped in the task-complete handler. Clearing it on the sync-completed *message* instead
    // would leave the app believing a sync was still running whenever the sync skipped early or
    // failed, because neither path sends that message, and no later edit would ever sync again.
    useEffect(() => {
        const unsubscribe = subscribeMobileTaskComplete((_taskId, result) => {
            const completed = result as unknown as ICompletedTaskResult;
            if (completed.type !== SYNC_TASK_TYPE) {
                return;
            }
            syncInFlightRef.current = false;
            log.event(`Sync task finished: ${completed.status}`);
            if (completed.status !== TaskStatus.Succeeded) {
                // The spinner was turned on by sync-started but no sync-completed will arrive, so
                // clear it here rather than leaving it spinning forever.
                syncCompletedCallbacksRef.current.forEach(callback => callback());
            }
        });
        return unsubscribe;
    }, []);

    const onDatabasesChanged = useCallback((_callback: () => void): (() => void) => {
        return () => {};
    }, []);

    const onDatabaseContentChanged = useCallback((callback: () => void): (() => void) => {
        databaseContentChangedCallbacksRef.current.add(callback);
        return () => {
            databaseContentChangedCallbacksRef.current.delete(callback);
        };
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
        return configStore.getDatabases(mobileDatabasesConfigFile);
    }, []);

    const addDatabase = useCallback(async (entry: IDatabaseEntry): Promise<IDatabaseEntry> => {
        const added = await configStore.addDatabase(mobileDatabasesConfigFile, entry);
        // Matches the desktop main process so smoke tests observe the same log line.
        log.info("Database entry added");
        return added;
    }, []);

    const updateDatabase = useCallback(async (originalName: string, entry: IDatabaseEntry): Promise<void> => {
        await configStore.updateDatabase(mobileDatabasesConfigFile, originalName, entry);
    }, []);

    const setDatabaseOrigin = useCallback(async (databasePath: string, origin: string | undefined): Promise<void> => {
        await configStore.setDatabaseOrigin(mobileDatabasesConfigFile, databasePath, origin);
    }, []);

    const removeDatabaseEntry = useCallback(async (name: string): Promise<void> => {
        await configStore.removeDatabase(mobileDatabasesConfigFile, name);
    }, []);

    const findDatabase = useCallback(async (name: string): Promise<IDatabaseEntry | undefined> => {
        return configStore.findDatabase(mobileDatabasesConfigFile, name);
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
        return configStore.getRecentDatabases(mobileDatabasesConfigFile);
    }, []);

    const removeRecentDatabaseName = useCallback(async (name: string): Promise<void> => {
        await configStore.removeRecentDatabase(mobileDatabasesConfigFile, name);
        // Matches the desktop main process so smoke tests observe the same log line.
        log.info(`Recent database removed: ${name}`);
    }, []);

    const listS3Dirs = useCallback(async (s3Key: string, bucket: string, prefix: string): Promise<string[]> => {
        // The WebView has no S3 client or vault access, so list directories via a background task on the
        // embedded worker (which has both). A failure (bad credentials, unreachable bucket) rejects here,
        // so the S3 browser shows a real error rather than the empty-array stub's fake empty bucket.
        const uuidGenerator = new RandomUuidGenerator();
        const queue = new TaskQueue(uuidGenerator, LIST_S3_DIRS_SOURCE);
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
        await importReceivedShare(mobileDatabasesConfigFile, secretStore, payload as IReceivedSharePayload, conflictResolutions as Record<string, IConflictResolution>);
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
    // Records whether an automatic sync is permitted, for the sync an edit starts.
    //
    // The log line keeps the wording the desktop main process uses, because the Electron test
    // 24-sync-settings waits on that exact text and both platforms answer the same question.
    //
    // It reaches nothing else. The background loop that syncs on its own runs natively and asks the
    // same question for itself, through the plan-sync task, because it runs while there is no WebView
    // to be told anything: this value would be whatever it was when the app was last on screen.
    //
    const setSyncAllowed = useCallback((allowed: boolean): void => {
        syncAllowedRef.current = allowed;
        log.info(`Sync gate set to ${allowed}`);
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
        backgroundImportDescription: BACKGROUND_IMPORT_DESCRIPTION,
        onShowNotification,
        onDatabaseContentChanged,
        onDatabasesChanged,
        onUpdateAvailable,
        openFolder,
        onPlatformEvent,
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
    //
    // The automatic import keys are the exception: they go to auto-import.toml in the storage
    // sandbox instead, and the two syncing keys go to sync.toml beside it. Local storage belongs to
    // the WebView and nothing else can read it, and both background loops run while there is no
    // WebView. The settings card is unchanged and still writes the same keys on every platform; the
    // routing is here because where they are kept is a platform's business.
    const config = createConfig(
        async (key) => {
            if (isAutoImportFileKey(key)) {
                return getAutoImportFileValue(mobileAutoImportConfigFile, key);
            }
            if (isSyncFileKey(key)) {
                return getSyncFileValue(mobileSyncConfigFile, key);
            }
            if (key === LAST_DATABASE_KEY) {
                return configStore.getLastDatabase(mobileDatabasesConfigFile);
            }
            return configStore.getConfigValue(persistentStore, key);
        },
        async (key, value) => {
            if (isAutoImportFileKey(key)) {
                await setAutoImportFileValue(mobileAutoImportConfigFile, key, value as boolean | string | IAutoImportSource[] | undefined);

                // Tell the background import to catch up with what was just written, rather than
                // having it find out on a timer.
                if (autoImportChangedRef.current) {
                    autoImportChangedRef.current();
                }
                return;
            }
            if (isSyncFileKey(key)) {
                await setSyncFileValue(mobileSyncConfigFile, key, value as boolean | undefined);
                return;
            }
            if (key === LAST_DATABASE_KEY) {
                await configStore.setLastDatabase(mobileDatabasesConfigFile, value as string | undefined);
                return;
            }
            configStore.setConfigValue(persistentStore, key, value);
        }
    );

    // Tells the interface to reload the open database whenever the app comes back to the screen.
    //
    // Photos reach the gallery as task messages announcing each one, and those are delivered to
    // whatever is listening at the time. While the app is off screen the WebView is suspended, so
    // every photo the background import takes in is announced to nobody, and nothing replays them
    // when it wakes. Without this the gallery goes on showing what it held when the user left,
    // however many photos have been backed up since, until they think to open the database again.
    //
    // The whole database is reloaded rather than the missed photos being worked out, because there
    // is no record of what was missed: the messages were sent while nothing was listening.
    useEffect(() => {
        const onVisibilityChange = () => {
            if (document.visibilityState !== "visible") {
                return;
            }

            databaseContentChangedCallbacksRef.current.forEach(callback => callback());
        };

        document.addEventListener("visibilitychange", onVisibilityChange);

        return () => {
            document.removeEventListener("visibilitychange", onVisibilityChange);
        };
    }, []);

    // Writes the syncing settings a fresh installation starts from, if nobody has written them yet.
    //
    // The background sync loop reads sync.toml, and a file it cannot read means syncing off, which
    // is the safe answer for a loop that would otherwise push photos over a metered connection on a
    // guess. That leaves a new phone with the two toggles showing syncing on and a file saying
    // nothing, so the app writes what the toggles say the first time it runs. A file that is already
    // there is left alone: rewriting it would put syncing back on for somebody who switched it off.
    useEffect(() => {
        seedSyncSettingsFile(mobileSyncConfigFile)
            .catch(error => log.exception("Failed to write the initial syncing settings", error as Error));
    }, []);

    // Starts the background automatic import when it is switched on, and stops it when it is
    // switched off.
    //
    // The WebView no longer drives the import itself. It used to hold a timer that queued an
    // import-assets task, which meant automatic import stopped the moment the app left the screen:
    // the operating system throttles and then stops a WebView's timers. The loop lives on the native
    // side now (a foreground service on Android, the plugin's driver on iOS), and this is reduced to
    // telling it to start or stop and asking for the photo permission first. Nothing here queues an
    // import on any platform, so there is never a second driver to race the native one.
    useEffect(() => {
        let cancelled = false;

        // True while a settings read is part way through acting on what it found. Without it a
        // second read arriving during the permission request gets past the "already started" check
        // on its way to starting the native driver twice.
        let acting = false;

        // True when the settings changed while the read above was part way through acting. The change
        // is acted on when that finishes rather than dropped: the permission request can sit on
        // screen for as long as the user leaves it there, and a toggle switched off in the meantime
        // would otherwise leave the app believing it had started something it had not.
        let changedWhileActing = false;

        const ensureAutoImport = async (): Promise<void> => {
            if (acting) {
                changedWhileActing = true;
                return;
            }

            acting = true;
            try {
                do {
                    changedWhileActing = false;
                    await ensureAutoImportOnce();
                }
                while (changedWhileActing && !cancelled);
            }
            finally {
                acting = false;
            }
        };

        const ensureAutoImportOnce = async (): Promise<void> => {
            const contents = await readAutoImportFile(mobileAutoImportConfigFile);
            const plan = planMobileAutoImport(contents.settings, contents.defaultDatabasePath);

            if (cancelled) {
                return;
            }

            if (!plan.shouldRun) {
                if (autoImportStartedRef.current) {
                    log.info("Stopping automatic import.");
                    autoImportStartedRef.current = false;
                }

                // Asked for unconditionally rather than only when this provider started it: the
                // service outlives the WebView, so a fresh WebView that finds the setting off has to
                // be able to stop a service left running by the one before it.
                await JsEngine.stopBackgroundImport();
                return;
            }

            if (autoImportStartedRef.current) {
                return;
            }

            // Asking for the permission before anything else: without it the library reads nothing,
            // and the setting has to go back off rather than looking as though photos are being
            // backed up when none can even be seen.
            const permission = readPermissionState(await JsEngine.requestMediaPermission());
            const outcome = resolveMediaPermission(permission);
            if (!outcome.enabled) {
                await setAutoImportFileValue(mobileAutoImportConfigFile, AUTO_IMPORT_ENABLED_KEY, false);
                log.info(`Automatic import switched off: ${outcome.message}`);
                return;
            }

            // Checked again here, not only at the top: the permission request takes a while, and the
            // provider can have gone away in the meantime.
            if (cancelled) {
                return;
            }

            // The native side works out the rest for itself, pass by pass, by asking the
            // plan-auto-import task: which database to import into, whether it has to be created
            // first, and how long to wait between passes. None of that is decided here, because none
            // of it can be while the app is off screen.
            await JsEngine.startBackgroundImport();
            autoImportStartedRef.current = true;
            log.info("Starting automatic import.");
        };

        // The progress line last written to the log, so the same one is not written again.
        let lastProgressLine: string | undefined = undefined;

        // The import's own log lines run inside the embedded engine and do not reach the app log, so
        // what automatic import is doing is only visible through the progress it streams back. This
        // still arrives while the app is on screen, whoever started the import, because the plugin
        // emits a task message for every running task. Logged rather than only shown on screen,
        // because a phone doing nothing and a phone quietly failing look the same in the interface.
        const progressUnsubscribe = subscribeMobileTaskMessage((_taskId, message) => {
            // Where the run's time went, written out as the run ends. This is the only way the
            // figure reaches anywhere readable: the import runs in the embedded engine, whose own
            // log never reaches the app log. Every run writes one, so a slow import on a real phone
            // can be accounted for rather than guessed at.
            if ((message as Record<string, unknown>).type === "import-timings") {
                const timingsMessage = message as unknown as IImportTimingsMessage;
                log.info(formatImportTimings(timingsMessage.timings));
                return;
            }

            if ((message as Record<string, unknown>).type !== "import-progress") {
                return;
            }
            const progress = message as unknown as IImportProgressMessage;
            const line = `Import: ${progress.imported} imported, ${progress.skipped} already there, ${progress.failed} failed.`;

            // Only when it says something it did not say last time. A pass reports its running totals
            // as it goes and the next pass starts a short while later, for as long as automatic
            // import is on, so logging every message buries everything else in the app log under the
            // same line repeated: the counts of a failure were once thirty identical lines deep,
            // which is exactly when the log is worth reading.
            if (line === lastProgressLine) {
                return;
            }
            lastProgressLine = line;
            log.info(line);
        });

        ensureAutoImport().catch(error => log.exception("Failed to start automatic import", error as Error));

        // The settings card writes the toggle through the config store, and on mobile that store
        // hands the automatic import keys to the settings file. Being told about the write is what
        // replaced the timer that used to re-read the settings every couple of seconds: the file is
        // read through the embedded worker now, so polling it would be a task dispatch every tick.
        autoImportChangedRef.current = () => {
            ensureAutoImport().catch(error => log.exception("Failed to update automatic import", error as Error));
        };

        return () => {
            cancelled = true;
            autoImportChangedRef.current = undefined;
            progressUnsubscribe();

            // The background import is deliberately left running. It is the whole point of it: the
            // WebView going away, which is what happens when the app leaves the screen, must not stop
            // photos being backed up.
        };
    }, []);

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
