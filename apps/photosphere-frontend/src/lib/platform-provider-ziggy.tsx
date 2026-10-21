import React, { ReactNode, useCallback, useEffect, useMemo, useRef } from "react";
import { flushSync } from "react-dom";
import eruda from "eruda";
import { PlatformContextProvider, ConfigContextProvider, StateContextProvider, createConfig, useLanShareTasks, readBrowserNetworkStatus, subscribeBrowserNetworkStatus, convertToPng, TEST_OPEN_DATABASE_EVENT, TEST_SEED_NEWS_EVENT, TEST_STAGE_EXPORT_EVENT, TEST_NOTIFY_DATABASE_EDITED_EVENT, type IPlatformContext, type IPlatformEvent, type INetworkStatus, type IToolsStatus, type IShowNotificationData, type IUpdateAvailableData, type IDatabaseEntry, type ISharedSecretEntry, type IPickFolderOptions, type ISaveDownloadResult, type ISeedNewsItem, UuidGeneratorProvider } from "user-interface";
import { TaskQueue, type ITaskResult } from "task-queue";
import { log, RandomUuidGenerator, TestUuidGenerator, type IUuidGenerator, type ILogDetails } from "utils";
import { planMobileAutoImport } from "api/src/lib/auto-import-mobile";
import type { IImportProgressMessage } from "api/src/lib/import-assets.types";
import { AUTO_IMPORT_ENABLED_KEY } from "user-interface";
import type { ISaveAssetItem, IConflictResolution } from "api";
import type { ISecret } from "vault";
import type { IJsonValue, IMenuEvent, IPlatformInfo, ITaskCompletedEvent, IZiggyBridge } from "ziggy-ui";
import { planBackgroundWork, readPermissionState, resolveMediaPermission, type IRawPermissionResult } from "./background-work";
import { readAutoImportSettings, readSyncSettings, recordSyncDatabase, seedSyncSettings } from "./mobile-settings";
import { resolveDroppedFilePath, type IDroppedFile } from "./dropped-file-path";
import { interpretMenuAction, logDirectoryOf, type MenuEffect } from "./menu-actions";
import { buildExportFileRequest, buildExportFilesRequest, saveDownloadsViaShareSheet, type ExportTestOutcome, type IExportFileReply, type IExportFilesReply, type IExportFolderReply, type ISaveAssetTaskData, type ISaveAssetsBatchTaskData } from "./mobile-export";
import { firstSeededNewsNotification } from "./seeded-news";
import { signalTestPageReady } from "./ziggy-test-transport";
import { isTestMode } from "./test-mode";
import { toJsonValue } from "./to-json-value";
import { AppMessages } from "./app-messages";

//
// Whether the app is running in test mode (?testMode=1 on the page's address).
//
const testMode = isTestMode();

//
// The uuid generator this platform provides to the app: deterministic under a smoke test so task ids
// are reproducible, otherwise the real random one.
//
const uuidGenerator: IUuidGenerator = testMode ? new TestUuidGenerator() : new RandomUuidGenerator();

//
// The settings the phone's background work has to be told about the moment they change. Every setting is written the same way; this
// only decides who needs telling afterwards. The syncing pair is here as well as the automatic import ones because the page decides
// whether the background sync should run, so switching syncing on while automatic import is off would otherwise wait for the next
// launch.
//
const BACKGROUND_WORK_CONFIG_KEYS: string[] = [
    'autoImportEnabled',
    'autoImportSources',
    'autoImportCleanupEnabled',
    'defaultDatabasePath',
    'syncEnabled',
    'syncOnlyOnWifi',
];


//
// Props for the Ziggy platform provider.
//
export interface IPlatformProviderZiggyProps {
    // The app below the provider.
    children: ReactNode | ReactNode[];

    // The bridge the shell injects into the page.
    ziggy: IZiggyBridge;

    // What the core reported about the device the app runs on.
    platform: IPlatformInfo;
}

//
// Whether the in-page Eruda console has been started and whether it is showing. A phone has no inspector the page can
// reach, so the page brings its own.
//
interface IErudaState {
    // Set once eruda.init has run.
    initialised: boolean;

    // Set while the console is showing.
    visible: boolean;
}

//
// Platform context provider for the app running on Ziggy, on a desktop or a phone. Everything the core owns (databases,
// the vault, recents, config and state, tasks, sharing, news and update marks) is reached the same way on both. What differs
// on a phone is decided by the platform kind the core reported.
//
export function PlatformProviderZiggy({ children, ziggy, platform }: IPlatformProviderZiggyProps) {
    // Photosphere's own messages and events, each named by its type, over the bridge.
    const messages = useMemo(() => new AppMessages(ziggy), [ziggy]);

    // What the automatic import card says about importing while the app is not on screen. A desktop imports while it is open, iOS
    // decides for itself when a background import runs, and Android keeps importing with the screen off.
    let backgroundImportDescription: string;
    if (platform.platformKind === "desktop") {
        backgroundImportDescription = "Runs whenever Photosphere is open, importing new photos as they appear.";
    }
    else if (platform.os === "ios") {
        backgroundImportDescription = "When the app is not open, iOS decides when to catch up, usually while the phone is charging.";
    }
    else {
        backgroundImportDescription = "Keeps importing when the app is closed and the screen is off, showing a notification while it does.";
    }


    // LAN database-sharing methods, dispatched through the shared task queue.
    const { startShareReceive, waitShareReceive, cancelShareReceive, waitForReceiver, sendToReceiver, cancelShareSend } = useLanShareTasks();

    // In test mode, the outcome a test staged for the next phone export in place of the shell's share or save sheet. Read and
    // cleared by the export it applies to, so each staged outcome serves exactly one export.
    const stagedExportOutcomeRef = useRef<ExportTestOutcome | undefined>(undefined);

    // Store callbacks for database-opened events
    const openedCallbacksRef = useRef<Set<(databasePath: string) => void>>(new Set());

    // Store callbacks for database-closed events
    const closedCallbacksRef = useRef<Set<() => void>>(new Set());

    // Store callbacks for theme-changed events
    const themeCallbacksRef = useRef<Set<(theme: 'light' | 'dark' | 'system') => void>>(new Set());

    // Store callbacks for menu actions
    const platformEventCallbacksRef = useRef<Set<(event: IPlatformEvent) => void>>(new Set());

    // Store callbacks for sync-started events
    const syncStartedCallbacksRef = useRef<Set<() => void>>(new Set());

    // Store callbacks for sync-completed events
    const syncCompletedCallbacksRef = useRef<Set<() => void>>(new Set());

    // Store callbacks for show-notification events
    const showNotificationCallbacksRef = useRef<Set<(data: IShowNotificationData) => void>>(new Set());

    // Store callbacks for databases-changed events
    const databasesChangedCallbacksRef = useRef<Set<() => void>>(new Set());

    // Store callbacks for update-available events
    const updateAvailableCallbacksRef = useRef<Set<(data: IUpdateAvailableData) => void>>(new Set());

    // Store callbacks for task-message events
    const taskMessageCallbacksRef = useRef<Set<(taskId: string, message: Record<string, unknown>) => void>>(new Set());

    // Store callbacks for task-completed events
    const taskCompleteCallbacksRef = useRef<Set<(taskId: string, result: Record<string, unknown>) => void>>(new Set());

    // Whether the Eruda console has been started and is showing.
    const erudaStateRef = useRef<IErudaState>({
        initialised: false,
        visible: false,
    });

    // What each background feature was last known to be doing, so a change in either is said out loud once rather than on every
    // settings write. They change independently: automatic import can be switched off while syncing carries on.
    const importRunningRef = useRef<boolean>(false);
    const syncRunningRef = useRef<boolean>(false);

    // Called when one of the settings the background work depends on is written, or a database is opened, so the work is told to start
    // or stop straight away rather than finding out later.
    const autoImportChangedRef = useRef<(() => void) | undefined>(undefined);

    // Called when the open database's content changed in a way the interface was not told about, so it reloads the database.
    const databaseContentChangedCallbacksRef = useRef<Set<() => void>>(new Set());

    // Writes the syncing settings a fresh installation starts from, if nobody has written them yet. The background sync loop reads
    // config.yaml, and a section it cannot read means syncing off, which is the safe answer for a loop that would otherwise push photos
    // over a metered connection on a guess. That leaves a new phone with the two toggles showing syncing on and a file saying nothing,
    // so the app writes what the toggles say the first time it runs. A section that is already there is left alone.
    useEffect(() => {
        seedSyncSettings()
            .catch(error => log.exception("Failed to write the initial syncing settings", error as Error));
    }, []);

    // Starts the background work when automatic import or syncing is switched on, and stops it when both are off. The work runs in the
    // core, as keep-alive tasks, so it carries on with the app off screen; this is reduced to telling the core to start or stop and
    // asking for the photo permission first. Nothing here queues an import, so there is never a second driver to race the core's.
    useEffect(() => {
        let cancelled = false;

        // True while a settings read is part way through acting on what it found. Without it a second read arriving during the
        // permission request gets past the "already started" check on its way to starting the work twice.
        let acting = false;

        // True when the settings changed while the read above was part way through acting. The change is acted on when that finishes
        // rather than dropped: the permission request can sit on screen for as long as the user leaves it there, and a toggle switched
        // off in the meantime would otherwise leave the app believing it had started something it had not.
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
            const contents = await readAutoImportSettings();
            const importPlan = planMobileAutoImport(contents.settings, contents.defaultDatabasePath);
            const syncSettings = await readSyncSettings();

            if (cancelled) {
                return;
            }

            // Either feature is a reason to run the background work. They are switched on separately, and syncing must not need
            // automatic import switched on as well: somebody who imports by hand and wants their edits pushed is not asking for their
            // photo library to be scanned.
            const syncEnabled = syncSettings.written && syncSettings.settings.enabled;
            const syncDatabasePath = syncSettings.databasePath ?? contents.defaultDatabasePath;
            const decision = planBackgroundWork({
                autoImportEnabled: importPlan.shouldRun && platform.platformKind === "mobile",
                syncEnabled,
                hasDatabaseToSync: syncDatabasePath !== undefined && syncDatabasePath.length > 0,
            });

            const syncWanted = decision.shouldRun && syncEnabled;
            let importWanted = importPlan.shouldRun && platform.platformKind === "mobile";

            // The photo permission, for automatic import only, and before anything is said about it starting: without it the library
            // reads nothing, and the setting has to go back off rather than looking as though photos are being backed up when none
            // can even be seen. Syncing never asks, because it moves what is already in the database.
            if (decision.needsMediaPermission && !importRunningRef.current) {
                const permission = readPermissionState(await messages.invoke<IRawPermissionResult>('requestMediaPermission', null));
                const outcome = resolveMediaPermission(permission);
                if (!outcome.enabled) {
                    importWanted = false;
                    await messages.invoke('set-config', { key: AUTO_IMPORT_ENABLED_KEY, value: false });
                    log.info(`Automatic import switched off: ${outcome.message}`);
                }
            }

            // Checked again here, not only at the top: the permission request takes a while, and the provider can have gone away in
            // the meantime.
            if (cancelled) {
                return;
            }

            // Each feature's own change is said out loud, whether or not the work itself starts or stops, because they change
            // independently. Said only once a refused permission has had its say, so nothing claims an import is starting that is
            // about to be switched off.
            if (importWanted !== importRunningRef.current) {
                importRunningRef.current = importWanted;
                log.info(importWanted ? "Starting automatic import." : "Stopping automatic import.");
            }
            if (syncWanted !== syncRunningRef.current) {
                syncRunningRef.current = syncWanted;
                log.info(syncWanted ? "Starting background syncing." : "Stopping background syncing.");
            }

            if (!importWanted && !syncWanted) {
                // Asked for unconditionally rather than only when this page started it: the work outlives the page, so a fresh page
                // that finds both settings off has to be able to stop work left running by the one before it.
                await messages.invoke('stopBackgroundImport', null);
                return;
            }

            // The core works out the rest for itself, pass by pass, by asking the plan-auto-import, plan-sync and plan-prefetch tasks:
            // which database each one works on, whether it should run at all, and how long to wait between passes. Asked for every
            // time either feature is wanted, not only the first time: a loop that ended has to be started again when its feature
            // comes back, and starting one that is already running does nothing.
            await messages.invoke('startBackgroundImport', null);
        };

        ensureAutoImport().catch(error => log.exception("Failed to start automatic import", error as Error));

        autoImportChangedRef.current = () => {
            ensureAutoImport().catch(error => log.exception("Failed to update automatic import", error as Error));
        };

        return () => {
            cancelled = true;
            autoImportChangedRef.current = undefined;

            // The background work is deliberately left running. It is the whole point of it: the page going away, which is what
            // happens when the app leaves the screen, must not stop photos being backed up.
        };
    }, [platform.platformKind, ziggy]);

    // What automatic import is doing is only visible through the progress it streams back. Logged rather than only shown on
    // screen, because an import doing nothing and one quietly failing look the same in the interface. On every platform: a phone
    // streams it from the background work, and a desktop from the import task its core runs.
    useEffect(() => {
        // The progress line last written to the log, so the same one is not written again.
        let lastProgressLine: string | undefined = undefined;

        const onProgress = (_taskId: string, message: Record<string, unknown>): void => {
            if (message.type !== "import-progress") {
                return;
            }
            const progress = message as unknown as IImportProgressMessage;
            const line = `Import: ${progress.imported} imported, ${progress.skipped} already there, ${progress.failed} failed, ${progress.skippedBeforeOpening} recognised before opening.`;

            // Only when it says something it did not say last time. A pass reports its running totals as it goes and the next pass
            // starts a short while later, for as long as automatic import is on, so logging every message buries everything else in
            // the app log under the same line repeated.
            if (line === lastProgressLine) {
                return;
            }
            lastProgressLine = line;
            log.info(line);
        };
        taskMessageCallbacksRef.current.add(onProgress);

        return () => {
            taskMessageCallbacksRef.current.delete(onProgress);
        };
    }, []);

    // Set up message listener for database-opened events
    useEffect(() => {
        const handleDatabaseOpened = (databasePath: string) => {
            // Notify all subscribers
            openedCallbacksRef.current.forEach(callback => {
                callback(databasePath);
            });
        };

        messages.onEvent('database-opened', handleDatabaseOpened);

        return () => {
            messages.removeAllListeners('database-opened');
        };
    }, [ziggy]);

    // Set up message listener for database-closed events
    useEffect(() => {
        const handleDatabaseClosed = () => {
            // Notify all subscribers
            closedCallbacksRef.current.forEach(callback => {
                callback();
            });
        };

        messages.onEvent('database-closed', handleDatabaseClosed);

        return () => {
            messages.removeAllListeners('database-closed');
        };
    }, [ziggy]);

    // Set up message listener for theme-changed events
    useEffect(() => {
        const handleThemeChanged = (theme: 'light' | 'dark' | 'system') => {
            // Notify all subscribers
            themeCallbacksRef.current.forEach(callback => {
                callback(theme);
            });
        };

        messages.onEvent('theme-changed', handleThemeChanged);

        return () => {
            messages.removeAllListeners('theme-changed');
        };
    }, [ziggy]);

    // Set up message listener for sync-started events
    useEffect(() => {
        const handleSyncStarted = () => {
            syncStartedCallbacksRef.current.forEach(cb => cb());
        };

        messages.onEvent('sync-started', handleSyncStarted);

        return () => {
            messages.removeAllListeners('sync-started');
        };
    }, [ziggy]);

    // Set up message listener for sync-completed events
    useEffect(() => {
        const handleSyncCompleted = () => {
            syncCompletedCallbacksRef.current.forEach(cb => cb());
        };

        messages.onEvent('sync-completed', handleSyncCompleted);

        return () => {
            messages.removeAllListeners('sync-completed');
        };
    }, [ziggy]);

    // Set up message listener for show-notification events
    useEffect(() => {
        const handleShowNotification = (data: IShowNotificationData) => {
            showNotificationCallbacksRef.current.forEach(cb => cb(data));
        };

        messages.onEvent('show-notification', handleShowNotification);

        return () => {
            messages.removeAllListeners('show-notification');
        };
    }, [ziggy]);

    // Set up message listener for databases-changed events
    useEffect(() => {
        const handleDatabasesChanged = () => {
            databasesChangedCallbacksRef.current.forEach(callback => callback());
        };

        messages.onEvent('databases-changed', handleDatabasesChanged);

        return () => {
            messages.removeAllListeners('databases-changed');
        };
    }, [ziggy]);

    // Set up message listener for update-available events
    useEffect(() => {
        const handleUpdateAvailable = (data: IUpdateAvailableData) => {
            updateAvailableCallbacksRef.current.forEach(cb => cb(data));
        };

        messages.onEvent('update-available', handleUpdateAvailable);

        return () => {
            messages.removeAllListeners('update-available');
        };
    }, [ziggy]);

    // Set up message listener for platform events pushed from the core.
    useEffect(() => {
        const handlePlatformEvent = (event: IPlatformEvent) => {
            platformEventCallbacksRef.current.forEach(callback => callback(event));
        };

        messages.onEvent('platform-event', handlePlatformEvent);

        return () => {
            messages.removeAllListeners('platform-event');
        };
    }, [ziggy]);

    // Set up message listener for navigate events sent by the core. Navigate by setting the route
    // hash directly rather than dispatching to a React subscriber: the app uses a HashRouter, so
    // the hash is the navigation primitive and it takes effect whatever is mounted. A
    // subscriber-based delivery would be lost whenever no subscriber is mounted (for example while the
    // Main subtree is torn down to show the top-level /stories route).
    useEffect(() => {
        const handleNavigate = (page: string) => {
            window.location.hash = page.startsWith('/') ? page : `/${page}`;
        };

        messages.onEvent('navigate', handleNavigate);

        return () => {
            messages.removeAllListeners('navigate');
        };
    }, [ziggy]);

    // Set up message listener for task-message events (import progress)
    useEffect(() => {
        const handleTaskMessage = (data: { taskId: string; message: Record<string, unknown> }) => {
            // Rendered before the next event is handled. A task the core runs quickly sends its progress and its completion
            // back to back, and React would otherwise fold them into one render, so the job list would go from empty to empty
            // and the job would never be seen to start.
            flushSync(() => {
                taskMessageCallbacksRef.current.forEach(cb => cb(data.taskId, data.message));
            });
        };

        ziggy.onTaskMessage(handleTaskMessage);

        return () => {
            ziggy.removeTaskMessageListener(handleTaskMessage);
        };
    }, [ziggy]);

    // Set up message listener for task-completed events (import completion)
    useEffect(() => {
        const handleTaskCompleted = (data: ITaskCompletedEvent) => {
            flushSync(() => {
                taskCompleteCallbacksRef.current.forEach(cb => cb(data.taskId, data.result as any as Record<string, unknown>));
            });
        };

        ziggy.onTaskCompleted(handleTaskCompleted);

        return () => {
            ziggy.removeTaskCompletedListener(handleTaskCompleted);
        };
    }, [ziggy]);

    //
    // Carries out what a menu action asks for. Everything the shell does itself never arrives here.
    //
    const runMenuEffect = useCallback(async (effect: MenuEffect): Promise<void> => {
        switch (effect.kind) {
            case 'navigate':
                window.location.hash = effect.page;
                return;
            case 'set-theme':
                // The core announces the change with a theme-changed event, which reaches the theme subscribers.
                await messages.invoke('set-config', { key: 'theme', value: effect.theme });
                return;
            case 'open-log-directory': {
                const logDetails = await messages.invoke<ILogDetails>('get-log-details', null);
                await messages.invoke('open-path', logDirectoryOf(logDetails.logFilePath));
                return;
            }
            case 'open-url':
                window.open(effect.url, '_blank', 'noopener');
                return;
            case 'close-database':
                closedCallbacksRef.current.forEach(callback => callback());
                return;
            case 'platform-event':
                platformEventCallbacksRef.current.forEach(callback => callback({ type: 'menu-action', action: effect.action }));
                return;
        }
    }, [ziggy]);

    // Set up the listener for the menu items the page runs. The core sends each as the app event {type: "menu", item}, which is not
    // laid out like Photosphere's own {type, data} events, so it is taken from the bridge here rather than through AppMessages.
    // Every other app event reaches this listener too and is skipped.
    useEffect(() => {
        const handleMenuEvent = (event: IMenuEvent) => {
            if (event.type !== "menu") {
                return;
            }
            void runMenuEffect(interpretMenuAction(event.item));
        };

        ziggy.onEvent(handleMenuEvent);

        return () => {
            ziggy.removeEventListener(handleMenuEvent);
        };
    }, [ziggy, runMenuEffect]);

    const openDatabase = useCallback(async (): Promise<void> => {
        if (platform.platformKind !== "desktop") {
            // No-op: no database picker on a phone yet.
            return;
        }
        await messages.invoke('open-database', null);
    }, [ziggy, platform.platformKind]);

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
        // Notify the core to add to recent databases
        await messages.invoke('notify-database-opened', databasePath);

        // Remember which database the background sync pushes, which is what makes it work for the database the user is actually
        // using. Opening a database can be the first thing that gives the background work something to do, so the decision about
        // whether to run it is worth taking again.
        recordSyncDatabase(databasePath)
            .then(() => {
                if (autoImportChangedRef.current) {
                    autoImportChangedRef.current();
                }
            })
            .catch(error => log.exception("Failed to record the database to sync", error as Error));

        // Fire opened callbacks so UI components (e.g. recent databases list) refresh.
        openedCallbacksRef.current.forEach(callback => {
            callback(databasePath);
        });
    }, [ziggy]);

    const notifyDatabaseClosed = useCallback(async (): Promise<void> => {
        // Notify the core to clear config
        await messages.invoke('notify-database-closed', null);
    }, [ziggy]);

    const onThemeChanged = useCallback((callback: (theme: 'light' | 'dark' | 'system') => void): (() => void) => {
        themeCallbacksRef.current.add(callback);
        return () => {
            themeCallbacksRef.current.delete(callback);
        };
    }, []);

    const notifyDatabaseEdited = useCallback((): void => {
        messages.send('notify-database-edited', null);
    }, [ziggy]);

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

    const onDatabasesChanged = useCallback((callback: () => void): (() => void) => {
        databasesChangedCallbacksRef.current.add(callback);
        return () => {
            databasesChangedCallbacksRef.current.delete(callback);
        };
    }, []);

    const onUpdateAvailable = useCallback((callback: (data: IUpdateAvailableData) => void): (() => void) => {
        updateAvailableCallbacksRef.current.add(callback);
        return () => {
            updateAvailableCallbacksRef.current.delete(callback);
        };
    }, []);

    const onPlatformEvent = useCallback((callback: (event: IPlatformEvent) => void): (() => void) => {
        platformEventCallbacksRef.current.add(callback);
        return () => {
            platformEventCallbacksRef.current.delete(callback);
        };
    }, []);

    const openFolder = useCallback(async (folderPath: string): Promise<void> => {
        if (platform.platformKind !== "desktop") {
            // No-op: a phone has no file manager to show a folder in.
            return;
        }
        await messages.invoke('open-path', folderPath);
    }, [ziggy, platform.platformKind]);

    const getPathForFile = useCallback((file: File): string | undefined => {
        return resolveDroppedFilePath(file as IDroppedFile, testMode, platform.platformKind === "desktop", droppedFile => ziggy.getPathForFile(droppedFile));
    }, [ziggy, platform.platformKind]);

    const checkTools = useCallback(async (): Promise<IToolsStatus> => {
        if (platform.platformKind !== "desktop") {
            // ImageMagick and ffmpeg are bundled inside the phone app, so they are available.
            return {
                magick: { available: true },
                ffprobe: { available: true },
                ffmpeg: { available: true },
                allAvailable: true,
                missingTools: [],
            };
        }
        return await messages.invoke<IToolsStatus>('check-tools', null);
    }, [ziggy, platform.platformKind]);

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

    // Cancels through the core's queue backend, the cancel-tasks main-command, for the reason ZiggyQueueBackend.cancelTasks gives:
    // Ziggy's own cancel-tasks channel left a cancelled import waiting for good on children that never started.
    const cancelTasks = useCallback(async (sessionId: string): Promise<void> => {
        messages.send('main-command', {
            command: 'cancel-tasks',
            source: sessionId,
        });
    }, [ziggy]);

    const getDatabases = useCallback(async (): Promise<IDatabaseEntry[]> => {
        return await messages.invoke<IDatabaseEntry[]>('get-databases', null);
    }, [ziggy]);

    const addDatabase = useCallback(async (entry: IDatabaseEntry): Promise<IDatabaseEntry> => {
        return await messages.invoke<IDatabaseEntry>('add-database', toJsonValue(entry));
    }, [ziggy]);

    const updateDatabase = useCallback(async (originalName: string, entry: IDatabaseEntry): Promise<void> => {
        await messages.invoke('update-database', { originalName, entry: toJsonValue(entry) });
    }, [ziggy]);

    const setDatabaseOrigin = useCallback(async (databasePath: string, origin: string | undefined): Promise<void> => {
        await messages.invoke('set-database-origin', { databasePath, origin: origin ?? null });
    }, [ziggy]);

    const removeDatabaseEntry = useCallback(async (name: string): Promise<void> => {
        await messages.invoke('remove-database-entry', name);
    }, [ziggy]);

    const findDatabase = useCallback(async (name: string): Promise<IDatabaseEntry | undefined> => {
        const found = await messages.invoke<IDatabaseEntry | null>('find-database', name);
        return found ?? undefined;
    }, [ziggy]);

    // Both platforms show the shell's folder dialog. On Android the dialog answers with a content:// tree address, where
    // the phone's earlier "Browse" prompt asked for a name and answered with a path inside the app's private storage.
    const pickFolder = useCallback(async (options?: IPickFolderOptions): Promise<string | undefined> => {
        const picked = await messages.invoke<string | null>('pick-folder', toJsonValue(options ?? null));
        return picked ?? undefined;
    }, [ziggy]);

    const pickFiles = useCallback(async (title: string): Promise<string[] | undefined> => {
        const picked = await messages.invoke<string[] | null>('pick-files', title);
        return picked ?? undefined;
    }, [ziggy]);

    //
    // Runs a task to its end on the core and gives its result. Used to write a download into the app's private storage before
    // the share sheet hands it out.
    //
    const runDownloadTask = useCallback(async (databasePath: string, taskType: string, data: ISaveAssetTaskData | ISaveAssetsBatchTaskData): Promise<ITaskResult> => {
        const queue = new TaskQueue(uuidGenerator, databasePath);
        try {
            const taskId = queue.addTask(taskType, data);
            const result = await queue.awaitTask(taskId);
            if (!result) {
                throw new Error(`The ${taskType} task was cancelled.`);
            }
            return result;
        }
        finally {
            queue.shutdown();
        }
    }, []);

    const saveDownloadedFiles = useCallback(async (items: ISaveAssetItem[], databasePath: string): Promise<ISaveDownloadResult> => {
        if (platform.platformKind === "desktop") {
            // One round trip: the core shows the destination dialog, writes the files and reports the outcome.
            return await messages.invoke<ISaveDownloadResult>('save-assets', { items: toJsonValue(items), databasePath });
        }

        // A phone cannot write to a place the user chooses, so the files are written into the app's private storage and the
        // shell's share sheet hands them out.
        const testOutcome = stagedExportOutcomeRef.current;
        stagedExportOutcomeRef.current = undefined;
        return await saveDownloadsViaShareSheet(items, databasePath, testOutcome, {
            newUuid: () => uuidGenerator.generate(),
            makeExportFolder: async folder => (await messages.invoke<IExportFolderReply>('exportTempFolder', { folder })).path,
            runTask: (taskType, data) => runDownloadTask(databasePath, taskType, data),
            exportFile: (path, outcome) => messages.invoke<IExportFileReply>('exportFile', toJsonValue(buildExportFileRequest(path, outcome))),
            exportFiles: (paths, outcome) => messages.invoke<IExportFilesReply>('exportFiles', toJsonValue(buildExportFilesRequest(paths, outcome))),
        });
    }, [ziggy, platform.platformKind, runDownloadTask]);

    const listSecrets = useCallback(async (): Promise<ISharedSecretEntry[]> => {
        const allSecrets = await messages.invoke<ISecret[]>('vault-list', null);
        return allSecrets.map((secretEntry: ISecret) => ({ name: secretEntry.name, type: secretEntry.type }));
    }, [ziggy]);

    const addSecret = useCallback(async (entry: ISharedSecretEntry, value: string): Promise<ISharedSecretEntry> => {
        const existing = await messages.invoke<ISecret | null>('vault-get', entry.name);
        if (existing) {
            throw new Error(`A secret named '${entry.name}' already exists.`);
        }
        await messages.invoke('vault-set', { name: entry.name, type: entry.type, value });
        return { name: entry.name, type: entry.type };
    }, [ziggy]);

    const updateSecret = useCallback(async (originalName: string, entry: ISharedSecretEntry, value?: string): Promise<void> => {
        if (value === undefined) {
            return;
        }

        // Set the new entry first, then delete the old one if the name changed.
        // Order matters: a crash between the two leaves data rather than losing it.
        await messages.invoke('vault-set', { name: entry.name, type: entry.type, value });
        if (originalName !== entry.name) {
            await messages.invoke('vault-delete', originalName);
        }
    }, [ziggy]);

    const deleteSecret = useCallback(async (name: string): Promise<void> => {
        await messages.invoke('vault-delete', name);
    }, [ziggy]);

    const getSecretValue = useCallback(async (name: string): Promise<string | undefined> => {
        const secret = await messages.invoke<ISecret | null>('vault-get', name);
        return secret?.value;
    }, [ziggy]);

    const getRecentDatabases = useCallback(async (): Promise<IDatabaseEntry[]> => {
        return await messages.invoke<IDatabaseEntry[]>('get-recent-databases', null);
    }, [ziggy]);

    const getLastDatabase = useCallback(async (): Promise<string | undefined> => {
        const lastDatabase = await messages.invoke<string | null>('get-last-database', null);
        return lastDatabase ?? undefined;
    }, [ziggy]);

    const removeRecentDatabaseName = useCallback(async (name: string): Promise<void> => {
        await messages.invoke('remove-recent-database-name', name);
    }, [ziggy]);

    const listS3Dirs = useCallback(async (s3Key: string, bucket: string, prefix: string): Promise<string[]> => {
        return await messages.invoke<string[]>('list-s3-dirs', { s3Key, bucket, prefix });
    }, [ziggy]);

    const importSharePayload = useCallback(async (payload: unknown, conflictResolutions: Record<string, IConflictResolution>): Promise<void> => {
        await messages.invoke('import-share-payload', { payload: toJsonValue(payload), conflictResolutions: toJsonValue(conflictResolutions) });
    }, [ziggy]);

    const markUpdateAsShown = useCallback(async (version: string): Promise<void> => {
        await messages.invoke('mark-update-shown', version);
    }, [ziggy]);

    const markNewsAsShown = useCallback(async (newsId: string): Promise<void> => {
        await messages.invoke('mark-news-shown', newsId);
    }, [ziggy]);

    const copyToClipboard = useCallback(async (blob: Blob, _contentType: string): Promise<void> => {
        if (platform.platformKind !== "desktop") {
            // No-op: native clipboard image support is not wired up on a phone.
            return;
        }
        const pngBlob = await convertToPng(blob);
        await navigator.clipboard.write([new ClipboardItem({ "image/png": pngBlob })]);
    }, [platform.platformKind]);

    //
    // Toggles the developer tools. A desktop asks the shell to, through the generic main-command channel, so no
    // developer-tools-specific channel is needed. A phone shows or hides the in-page Eruda console, the only inspector
    // reachable from inside its web view.
    //
    const toggleDevTools = useCallback((): void => {
        if (platform.platformKind === "desktop") {
            messages.send('main-command', 'toggle-devtools');
            return;
        }
        const erudaState = erudaStateRef.current;
        if (!erudaState.initialised) {
            eruda.init();
            erudaState.initialised = true;
        }
        if (erudaState.visible) {
            eruda.hide();
        }
        else {
            eruda.show();
        }
        erudaState.visible = !erudaState.visible;
    }, [ziggy, platform.platformKind]);

    //
    // Reports online state and connection type from the browser's Network Information API (navigator.connection).
    // The browser's answer is used on every platform, because the Capacitor Network plugin, which a phone app used
    // to fall back on where the web view reports no connection type, does not exist here.
    //
    const getNetworkStatus = useCallback(async (): Promise<INetworkStatus> => {
        return readBrowserNetworkStatus();
    }, []);

    //
    // Fires the callback when the page reports going online/offline or the connection type changes.
    //
    const onNetworkStatusChange = useCallback((callback: (status: INetworkStatus) => void): (() => void) => {
        return subscribeBrowserNetworkStatus(callback);
    }, []);

    //
    // Pushes the shared sync decision (whether syncing is allowed) to the core via the generic main-command channel, so no
    // sync-specific channel is needed.
    //
    const setSyncAllowed = useCallback((allowed: boolean): void => {
        messages.send('main-command', { command: 'set-sync-allowed', allowed });
    }, [ziggy]);

    // Tells the core the page has loaded and is listening for events, which starts the checks for an update and for news. The
    // listeners of the components below this provider are set up before this runs, so the toast a check asks for is not lost.
    useEffect(() => {
        messages.send('main-command', { command: 'page-loaded' });
    }, [ziggy]);

    // In test mode, the shared test driver's window events are turned into the app's own callbacks, so a test exercises the
    // real code paths. Only then does the page tell the core it is listening for test commands, so no command arrives before its
    // listener exists.
    useEffect(() => {
        if (!testMode) {
            return;
        }
        const handleOpenDatabase = (event: Event) => {
            const databasePath = (event as CustomEvent<string>).detail;
            openedCallbacksRef.current.forEach(callback => callback(databasePath));

            // Opening a database from the databases list tells the core which database is open, which is what lets the sync run for it.
            notifyDatabaseOpened(databasePath)
                .catch(error => {
                    log.exception("Failed to tell the core a database was opened", error as Error);
                });
        };
        const handleSeedNews = (event: Event) => {
            const notification = firstSeededNewsNotification((event as CustomEvent<ISeedNewsItem[]>).detail);
            if (notification !== undefined) {
                showNotificationCallbacksRef.current.forEach(callback => callback(notification));
            }
        };
        const handleStageExport = (event: Event) => {
            stagedExportOutcomeRef.current = (event as CustomEvent<ExportTestOutcome>).detail;
        };
        const handleNotifyDatabaseEdited = () => {
            notifyDatabaseEdited();
        };
        window.addEventListener(TEST_OPEN_DATABASE_EVENT, handleOpenDatabase);
        window.addEventListener(TEST_SEED_NEWS_EVENT, handleSeedNews);
        window.addEventListener(TEST_NOTIFY_DATABASE_EDITED_EVENT, handleNotifyDatabaseEdited);
        window.addEventListener(TEST_STAGE_EXPORT_EVENT, handleStageExport);
        signalTestPageReady(ziggy);
        return () => {
            window.removeEventListener(TEST_OPEN_DATABASE_EVENT, handleOpenDatabase);
            window.removeEventListener(TEST_SEED_NEWS_EVENT, handleSeedNews);
            window.removeEventListener(TEST_NOTIFY_DATABASE_EDITED_EVENT, handleNotifyDatabaseEdited);
            window.removeEventListener(TEST_STAGE_EXPORT_EVENT, handleStageExport);
        };
    }, [ziggy, notifyDatabaseEdited, notifyDatabaseOpened]);

    const onDatabaseContentChanged = useCallback((callback: () => void): (() => void) => {
        databaseContentChangedCallbacksRef.current.add(callback);
        return () => {
            databaseContentChangedCallbacksRef.current.delete(callback);
        };
    }, []);

    // Tells the interface to reload the open database whenever the app comes back to the screen, on a phone.
    //
    // Photos reach the gallery as task messages announcing each one, and those are delivered to whatever is listening at the time.
    // While the app is off screen the web view is suspended, so every photo the background import takes in is announced to nobody, and
    // nothing replays them when it wakes. Without this the gallery goes on showing what it held when the user left, however many
    // photos have been backed up since, until they think to open the database again.
    //
    // The whole database is reloaded rather than the missed photos being worked out, because there is no record of what was missed:
    // the messages were sent while nothing was listening.
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
        backgroundImportDescription,
        onShowNotification,
        onDatabaseContentChanged,
        onDatabasesChanged,
        onUpdateAvailable,
        openFolder,
        onPlatformEvent,
        getPathForFile,
        supportsDragAndDropImport: platform.platformKind === "desktop",
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
        pickFiles,
        saveDownloadedFiles,
        listSecrets,
        addSecret,
        updateSecret,
        deleteSecret,
        getSecretValue,
        getRecentDatabases,
        getLastDatabase,
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

    // A pair of messages per file, so neither end has to work out where a key belongs: the caller
    // reaches for the store it means and the handler on the other side opens one file.
    //
    // The core replies null for a key nothing is stored under, while callers of IConfig treat
    // "not stored" as undefined (a null would be passed on as a value, for example to a switch's
    // checked prop, turning a controlled input into an uncontrolled one).
    //
    const config = createConfig(
        async (key) => {
            const value = await messages.invoke('get-config', key);
            return value === null ? undefined : value;
        },
        async (key, value) => {
            await messages.invoke('set-config', { key, value: value as IJsonValue });
            if (BACKGROUND_WORK_CONFIG_KEYS.includes(key) && autoImportChangedRef.current) {
                autoImportChangedRef.current();
            }
        }
    );

    const state = createConfig(
        async (key) => {
            const value = await messages.invoke('get-state', key);
            return value === null ? undefined : value;
        },
        (key, value) => messages.invoke('set-state', { key, value: value as IJsonValue })
    );

    return (
        <UuidGeneratorProvider value={uuidGenerator}>
            <ConfigContextProvider value={config}>
                <StateContextProvider value={state}>
                    <PlatformContextProvider value={platformContext}>
                        {children}
                    </PlatformContextProvider>
                </StateContextProvider>
            </ConfigContextProvider>
        </UuidGeneratorProvider>
    );
}
