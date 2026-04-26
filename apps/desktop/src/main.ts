import { app, BrowserWindow, ipcMain, utilityProcess, type UtilityProcess, dialog, Menu, shell } from 'electron';
import { appendFileSync } from 'fs';
import { join, dirname, basename } from 'path';
import { randomUUID } from 'crypto';
import { cpus, platform, arch, release } from 'os';
import { version } from 'config';
import { existsSync, readdirSync, statSync, readFileSync } from 'fs';
import type { IQueueBackend, ITaskMessageData } from 'task-queue';
import { TaskQueue, TaskStatus, setQueueBackend } from 'task-queue';
import { WorkerPoolElectronMain } from './lib/worker-pool-electron-main';
import { RandomUuidGenerator, TimestampProvider, logExceptions, log } from 'utils';
import { findAvailablePort } from 'node-utils';
import { loadDesktopConfig, saveDesktopConfig, updateLastFolder, getTheme, setTheme, updateLastDownloadFolder, getDatabases, addDatabaseEntry, updateDatabaseEntry, removeDatabaseEntry, getRecentDatabases, markDatabaseOpenedByPath } from 'api';
import type { IWorkerPoolOptions } from './lib/worker-pool-electron-main';
import type { IRestApiWorkerStopMessage, IRestApiWorkerStartMessage } from './rest-api-worker';
import { FileLoggerElectron } from './lib/file-logger-electron';
import type { IImportSession, IRendererLogMessage, ISaveAssetItem, IDatabaseEntry, IDatabaseSecrets } from 'electron-defs';
import { verifyTools } from 'tools';
import type { IDatabaseDescriptor, IDesktopConfig } from 'api';
import { createStorage, CloudStorage } from 'storage';
import { checkConnectivity, loadDatabaseConfig } from 'api';
import { getVault, getDefaultVaultType } from 'vault';
import { LanShareSender, LanShareReceiver, importDatabasePayload, importSecretPayload } from 'lan-share';
import type { IDatabaseSharePayload, ISecretSharePayload, IReceiverEndpoint, IConflictResolution } from 'lan-share';

// Main application window
let mainWindow: BrowserWindow | null = null;

// Worker pool for background task processing
let workerPool: IQueueBackend | null = null;

// REST API utility process
let restApiWorker: UtilityProcess | null = null;

// Flag to prevent restarting workers during shutdown
let isShuttingDown: boolean = false;

// Port number for the REST API server
let restApiPort: number | null = null;

// Tracks whether a database is currently open (used for menu state)
let isDatabaseOpen: boolean = false;

// Path of the currently open database; null when none.
let currentDatabasePath: string | null = null;

// Debounce timer for edit-triggered sync (10 seconds).
let syncDebounceTimer: NodeJS.Timeout | null = null;

// Periodic sync timer (5 minutes), runs for app lifetime.
let syncPeriodicTimer: NodeJS.Timeout | null = null;

// Prevents concurrent sync tasks; set by enqueueSyncTask(), cleared by syncStopped().
let isSyncRunning: boolean = false;

// File logger for writing logs to files
let fileLogger: FileLoggerElectron | null = null;

// Active LAN share sender instance, if any.
let activeSender: LanShareSender | null = null;

// Active LAN share receiver instance, if any.
let activeReceiver: LanShareReceiver | null = null;


//
// Creates and configures the main browser window for the Electron app.
//
async function createMainWindow() {
    if (restApiPort === null) {
        throw new Error('REST API port not initialized');
    }

    mainWindow = new BrowserWindow({
        width: 1200,
        height: 800,
        title: `Photosphere ${version}`,
        webPreferences: {
            nodeIntegration: false,
            contextIsolation: true,
            preload: join(app.getAppPath(), 'bundle/preload.js'),
        },
    });

    // mainWindow.webContents.openDevTools();


    // Load theme preference to pass to frontend
    const theme = await getTheme();

    // Load from built frontend (works in both dev and production)
    // Pass restApiUrl and theme as query parameters so the frontend can use them
    const htmlPath = join(app.getAppPath(), 'bundle/frontend/index.html');
    const restApiUrl = `http://localhost:${restApiPort}`;
    const fileUrl = `file://${htmlPath}?restApiUrl=${encodeURIComponent(restApiUrl)}&theme=${encodeURIComponent(theme)}`;
    mainWindow.loadURL(fileUrl);

    mainWindow.on('closed', () => {
        mainWindow = null;
    });

    // Open all external links in the system's default web browser instead of Electron.
    mainWindow.webContents.setWindowOpenHandler(({ url }) => {
        shell.openExternal(url);
        return { action: 'deny' };
    });

    mainWindow.webContents.on('will-navigate', (event, url) => {
        if (!url.startsWith('file://')) {
            event.preventDefault();
            shell.openExternal(url);
        }
    });
}

// Enforce single instance: if another instance is already running, focus its window and quit.
const gotSingleInstanceLock = app.requestSingleInstanceLock();
if (!gotSingleInstanceLock) {
    app.quit();
}
else {
    app.on('second-instance', () => {
        if (mainWindow) {
            if (mainWindow.isMinimized()) {
                mainWindow.restore();
            }
            mainWindow.focus();
        }
    });
}

app.whenReady().then(async () => {
    // Initialize file logger first so we can log everything
    fileLogger = await FileLoggerElectron.create(app.getPath('userData'));
    fileLogger.info('Photosphere Desktop starting...', 'Main');
    
    // Initialize REST API before creating main window
    await initRestApi();

    // Create application menu
    await createMenu();
    
    // Start up the background workers
    initWorkers();

    // Start periodic sync timer (runs for app lifetime; no-op when no database is not open)
    startPeriodicSync();

    await createMainWindow();

    app.on('activate', async () => {
        if (BrowserWindow.getAllWindows().length === 0) {
            await createMainWindow();
        }
    });
});

app.on('window-all-closed', () => {
    if (process.platform !== 'darwin') {
        app.quit();
    }
});

app.on('before-quit', async () => {
    isShuttingDown = true;

    stopPeriodicSync();
    if (syncDebounceTimer !== null) { //todo: this should be a function call to clean up.
        clearTimeout(syncDebounceTimer);
        syncDebounceTimer = null;
    }

    if (fileLogger) {
        fileLogger.info('Photosphere Desktop shutting down...', 'Main');
    }
    
    // Cleanup worker pool
    if (workerPool) {
        workerPool.shutdown();
        workerPool = null;
    }

    // Cleanup REST API utility process
    if (restApiWorker) {
        // Send stop message to utility process
        const stopMessage: IRestApiWorkerStopMessage = { type: 'stop' };
        restApiWorker.postMessage(stopMessage);
        // Terminate the process
        restApiWorker.kill();
        restApiWorker = null;
    }
    
    // Close file logger last to capture all shutdown logs
    if (fileLogger) {
        await fileLogger.close();
        fileLogger = null;
    }
});

// IPC handler for FPS measurements — only active when FPS_LOGGING=1
if (process.env.FPS_LOGGING === '1') {
    const fpsLogPath = '/tmp/photosphere-fps.csv';
    appendFileSync(fpsLogPath, 'timestamp,fps\n');
    ipcMain.on('fps-measurement', (_event, fps: number) => {
        appendFileSync(fpsLogPath, `${Date.now()},${fps}\n`);
    });
}

// IPC handler for adding tasks
ipcMain.on('add-task', (_event, taskType: string, data: any, source: string, taskId?: string) => {
    if (!workerPool) {
        console.error('Worker pool not initialized');
        return;
    }

    workerPool.addTask(taskType, data, source, taskId);
});

// IPC handler for cancelling tasks
ipcMain.on('cancel-tasks', (_event, source: string) => {
    if (!workerPool) {
        return;
    }

    workerPool.cancelTasks(source);
});

// IPC handler for opening file dialog
// Note: ipcMain.handle automatically catches errors from async functions and sends them to the renderer.
// If the handler throws or returns a rejected promise, Electron serializes the error and sends it to the renderer.
// The renderer can catch it when calling ipcRenderer.invoke().
ipcMain.handle('open-file', logExceptions(openDatabase, 'Error opening database'));
ipcMain.handle('create-database', logExceptions(createNewDatabase, 'Error creating database'));

// IPC handler for removing a database entry by path (secrets are independent and managed via the secrets page)
ipcMain.handle('remove-database-entry', logExceptions(async (_event, databasePath: string) => {
    await removeDatabaseEntry(databasePath);
}, 'Error removing database entry'));

// IPC handler for retrieving a vault secret by name
ipcMain.handle('vault-get', logExceptions(async (_event, name: string) => {
    const vault = getVault(getDefaultVaultType());
    return await vault.get(name);
}, 'Error getting vault secret'));

// IPC handler for creating or overwriting a vault secret
ipcMain.handle('vault-set', logExceptions(async (_event, secret: { name: string; type: string; value: string }) => {
    const vault = getVault(getDefaultVaultType());
    await vault.set(secret);
}, 'Error setting vault secret'));

// IPC handler for deleting a vault secret by name
ipcMain.handle('vault-delete', logExceptions(async (_event, name: string) => {
    const vault = getVault(getDefaultVaultType());
    await vault.delete(name);
}, 'Error deleting vault secret'));

// IPC handler for listing all vault secrets
ipcMain.handle('vault-list', logExceptions(async () => {
    const vault = getVault(getDefaultVaultType());
    return await vault.list();
}, 'Error listing vault secrets'));

// IPC handler for creating a database at a known path (no file picker)
ipcMain.handle('create-database-at-path', logExceptions(async (_event, databasePath: string) => {
    if (!workerPool) {
        throw new Error('Worker pool not initialized');
    }

    const uuidGenerator = new RandomUuidGenerator();
    const createQueue = new TaskQueue(uuidGenerator, databasePath);
    const taskId = randomUUID();
    createQueue.addTask('create-database', { databasePath }, taskId);
    await createQueue.awaitTask(taskId);
    createQueue.shutdown();

    if (mainWindow) {
        mainWindow.webContents.send('database-opened', databasePath);
    }
}, 'Error creating database at path'));

// IPC handler for checking whether a database is accessible (works for local FS, S3, etc.)
ipcMain.handle('check-database-exists', logExceptions(async (_event, databasePath: string) => {
    const vault = getVault(getDefaultVaultType());
    const databases = await getDatabases();
    const dbEntry = databases.find(entry => entry.path === databasePath);
    let s3Credentials = undefined;

    if (dbEntry?.s3Key) {
        const s3Secret = await vault.get(dbEntry.s3Key);
        if (s3Secret) {
            const parsed = JSON.parse(s3Secret.value);
            s3Credentials = {
                region: parsed.region,
                accessKeyId: parsed.accessKeyId,
                secretAccessKey: parsed.secretAccessKey,
                endpoint: parsed.endpoint,
            };
        }
    }

    return checkConnectivity(databasePath, s3Credentials);
}, 'Error checking database exists'));

// IPC handler for returning all configured database entries
ipcMain.handle('get-databases', logExceptions(async () => {
    return await getDatabases();
}, 'Error getting databases'));

// IPC handler for adding a new database entry
ipcMain.handle('add-database', logExceptions(async (_event, entry: IDatabaseEntry) => {
    await addDatabaseEntry(entry);
    return entry;
}, 'Error adding database'));

// IPC handler for updating an existing database entry
ipcMain.handle('update-database', logExceptions(async (_event, entry: IDatabaseEntry) => {
    await updateDatabaseEntry(entry);
}, 'Error updating database'));

// IPC handler for reading vault secrets for a database (resolved via shared secret reference IDs)
ipcMain.handle('get-database-secrets', logExceptions(async (_event, databasePath: string) => {
    const vault = getVault(getDefaultVaultType());
    const databases = await getDatabases();
    const dbEntry = databases.find(entry => entry.path === databasePath);
    const secrets: IDatabaseSecrets = {};

    if (dbEntry) {
        if (dbEntry.s3Key) {
            const s3Secret = await vault.get(dbEntry.s3Key);
            if (s3Secret) {
                const parsed = JSON.parse(s3Secret.value);
                secrets.s3Credentials = {
                    region: parsed.region,
                    accessKeyId: parsed.accessKeyId,
                    secretAccessKey: parsed.secretAccessKey,
                    endpoint: parsed.endpoint,
                };
            }
        }
        if (dbEntry.encryptionKey) {
            const encryptionSecret = await vault.get(dbEntry.encryptionKey);
            if (encryptionSecret) {
                const parsed = JSON.parse(encryptionSecret.value);
                secrets.encryptionKeyPair = {
                    privateKeyPem: parsed.privateKeyPem,
                    publicKeyPem: parsed.publicKeyPem,
                };
            }
        }
        if (dbEntry.geocodingKey) {
            const geocodingSecret = await vault.get(dbEntry.geocodingKey);
            if (geocodingSecret) {
                const parsed = JSON.parse(geocodingSecret.value);
                secrets.geocodingApiKey = parsed.apiKey;
            }
        }
    }

    return secrets;
}, 'Error getting database secrets'));

// IPC handler for opening a directory picker and returning the chosen path
ipcMain.handle('pick-folder', logExceptions(async () => {
    return await showDirectoryPicker('Select Folder');
}, 'Error picking folder'));

// IPC handler for notifying that database was opened from frontend
ipcMain.handle('notify-database-opened', logExceptions(async (_event, databasePath: string) => {
    const vault = getVault(getDefaultVaultType());
    const databases = await getDatabases();
    const dbEntry = databases.find(entry => entry.path === databasePath);
    let s3Credentials = undefined;

    if (dbEntry?.s3Key) {
        const s3Secret = await vault.get(dbEntry.s3Key);
        if (s3Secret) {
            const parsed = JSON.parse(s3Secret.value);
            s3Credentials = {
                region: parsed.region,
                accessKeyId: parsed.accessKeyId,
                secretAccessKey: parsed.secretAccessKey,
                endpoint: parsed.endpoint,
            };
        }
    }

    const { rawStorage } = createStorage(databasePath, s3Credentials);
    const dbConfig = await loadDatabaseConfig(rawStorage);
    const origin = dbConfig?.origin;
    const existing = databases.find(existingEntry => existingEntry.path === databasePath);
    if (!existing) {
        const newEntry: IDatabaseEntry = {
            name: basename(databasePath),
            description: '',
            path: databasePath,
            origin,
        };
        await addDatabaseEntry(newEntry);
    }
    else if (existing.origin !== origin) {
        await updateDatabaseEntry({ ...existing, origin });
    }
    await markDatabaseOpenedByPath(databasePath);
    const desktopConfig = await loadDesktopConfig();
    desktopConfig.lastDatabase = databasePath;
    await saveDesktopConfig(desktopConfig);
    isDatabaseOpen = true;
    await updateMenu();
    resetSyncState();
    currentDatabasePath = databasePath;
}, 'Error notifying database opened'));

// IPC handler for returning the top-5 most recently opened database entries
ipcMain.handle('get-recent-databases', logExceptions(async () => {
    return await getRecentDatabases();
}, 'Error getting recent databases'));

// IPC handler for listing directory names under an S3 bucket and prefix
ipcMain.handle('list-s3-dirs', logExceptions(async (_event, credentialId: string, bucket: string, prefix: string) => {
    const vault = getVault(getDefaultVaultType());
    const secret = await vault.get(credentialId);
    if (!secret) {
        return [];
    }
    const parsed = JSON.parse(secret.value);
    const storage = new CloudStorage(bucket, {
        accessKeyId: parsed.accessKeyId,
        secretAccessKey: parsed.secretAccessKey,
        region: parsed.region,
        endpoint: parsed.endpoint,
    });
    const result = await storage.listDirs(`${bucket}/${prefix}`, 100);
    return result.names;
}, 'Error listing S3 directories'));

// IPC handler for notifying that database was closed from frontend
ipcMain.handle('notify-database-closed', logExceptions(async () => {
    const desktopConfig = await loadDesktopConfig();
    delete desktopConfig.lastDatabase;
    await saveDesktopConfig(desktopConfig);
    isDatabaseOpen = false;
    await updateMenu();
    resetSyncState();
    currentDatabasePath = null;
}, 'Error notifying database closed'));

// IPC handler for notifying that the database was edited (triggers debounced sync)
ipcMain.on('notify-database-edited', () => {
    scheduleSync();
});

// IPC handler for reading a value from the desktop config file
ipcMain.handle('get-config', logExceptions(async (_event, key: string) => {
    const config = await loadDesktopConfig();
    return config[key as keyof IDesktopConfig];
}, 'Error getting config value'));

// IPC handler for writing a value to the desktop config file
ipcMain.handle('set-config', logExceptions(async (_event, key: string, value: IDesktopConfig[keyof IDesktopConfig]) => {
    const config = await loadDesktopConfig();
    (config as Record<string, IDesktopConfig[keyof IDesktopConfig]>)[key] = value;
    await saveDesktopConfig(config);
    // Keep the theme-changed event so the menu bar can react to theme changes
    if (key === 'theme' && mainWindow) {
        mainWindow.webContents.send('theme-changed', value);
    }
}, 'Error setting config value'));

// IPC handler for saving an asset to a user-chosen file path via save dialog.
// IPC handler for showing a save dialog and enqueuing a background task to stream the asset to the chosen file.
ipcMain.handle('save-asset', logExceptions(async (_event, assetId: string, assetType: string, filename: string, databasePath: string): Promise<void> => {
    const config = await loadDesktopConfig();
    const defaultPath = config.lastDownloadFolder
        ? join(config.lastDownloadFolder, filename)
        : filename;

    const result = await dialog.showSaveDialog(mainWindow!, {
        defaultPath,
    });

    if (result.canceled || !result.filePath) {
        return;
    }

    if (!workerPool) {
        throw new Error('Worker pool not initialized');
    }

    const destPath = result.filePath;
    await updateLastDownloadFolder(dirname(destPath));
    workerPool.addTask("save-asset", { assetId, assetType, destPath, databasePath }, databasePath);
}, 'Error saving asset'));

// IPC handler for showing a folder picker and enqueuing background tasks to save multiple assets.
ipcMain.handle('save-assets', logExceptions(async (_event, assets: ISaveAssetItem[], databasePath: string): Promise<void> => {
    const config = await loadDesktopConfig();

    const result = await dialog.showOpenDialog(mainWindow!, {
        properties: ['openDirectory', 'createDirectory'],
        title: 'Choose folder to save assets',
        defaultPath: config.lastDownloadFolder,
    });

    if (result.canceled || result.filePaths.length === 0) {
        return;
    }

    if (!workerPool) {
        throw new Error('Worker pool not initialized');
    }

    const folderPath = result.filePaths[0];
    await updateLastDownloadFolder(folderPath);
    workerPool.addTask("save-assets-batch", { assets, folderPath, databasePath }, databasePath);
}, 'Error saving assets'));

// IPC handler for opening a folder in the system's file manager
ipcMain.handle('open-path', logExceptions(async (_event, folderPath: string): Promise<void> => {
    await shell.openPath(folderPath);
}, 'Error opening path'));

// IPC handler for importing assets — opens a directory picker when paths is omitted
ipcMain.handle('import-assets', logExceptions(async (_event, paths?: string[]) => {
    return await selectAndImportAssets(paths);
}, 'Error importing assets'));

// IPC handler for starting a LAN share receiver.
// Accepts the pairing code from the caller (generated by the sender and entered by the user).
ipcMain.handle('start-share-receive', logExceptions(async (_event, code: string) => {
    activeReceiver = new LanShareReceiver(60000);
    await activeReceiver.start(code);
}, 'Error starting share receiver'));

// IPC handler for waiting for a sender payload on the active receiver
ipcMain.handle('wait-share-receive', logExceptions(async () => {
    if (!activeReceiver) {
        throw new Error('No active share receiver');
    }
    const payload = await activeReceiver.receive();
    activeReceiver = null;
    return payload;
}, 'Error waiting for share payload'));

// IPC handler for cancelling the active share receiver
ipcMain.handle('cancel-share-receive', logExceptions(async () => {
    if (activeReceiver) {
        activeReceiver.cancel();
        activeReceiver = null;
    }
}, 'Error cancelling share receiver'));

// IPC handler for creating a sender and waiting for a receiver on the LAN.
// Returns the receiver endpoint, or null on timeout or cancellation.
ipcMain.handle('wait-for-receiver', logExceptions(async (_event, payload: IDatabaseSharePayload | ISecretSharePayload, code: string) => {
    activeSender = new LanShareSender(payload, code);
    return await activeSender.waitForReceiver(60000);
}, 'Error waiting for receiver'));

// IPC handler for sending a payload to a discovered receiver.
ipcMain.handle('send-to-receiver', logExceptions(async (_event, endpoint: IReceiverEndpoint) => {
    if (!activeSender) {
        throw new Error('No active share sender');
    }
    const result = await activeSender.send(endpoint);
    activeSender = null;
    return result;
}, 'Error sending to receiver'));

// IPC handler for cancelling the active share sender
ipcMain.handle('cancel-share-send', logExceptions(async () => {
    if (activeSender) {
        activeSender.cancel();
        activeSender = null;
    }
}, 'Error cancelling share sender'));

//
// Secret share payload extended with the name to save it under on this device.
//
interface ISecretShareImportPayload extends ISecretSharePayload {
    // The vault key name chosen by the user on the receiving device.
    saveName: string;
}

// IPC handler for importing a share payload (database or secret)
ipcMain.handle('import-share-payload', logExceptions(async (_event, payload: IDatabaseSharePayload | ISecretShareImportPayload, conflictResolutions: Record<string, IConflictResolution>) => {
    if (payload.type === 'database') {
        const resolver = async (secretName: string) => conflictResolutions[secretName] ?? { action: 'replace' as const };
        const dbEntry = await importDatabasePayload(payload, resolver);
        await addDatabaseEntry(dbEntry);
    }
    else if (payload.type === 'secret') {
        const secretPayload = payload as ISecretShareImportPayload;
        await importSecretPayload(secretPayload, secretPayload.saveName);
    }
}, 'Error importing share payload'));

// IPC handler for checking whether required tools (ImageMagick, ffmpeg) are available
ipcMain.handle('check-tools', logExceptions(async () => {
    return await verifyTools();
}, 'Error checking tools'));

// IPC handler for renderer log messages
ipcMain.on('renderer-log', (event, message: IRendererLogMessage) => {
    if (fileLogger) {
        fileLogger.handleWorkerLogMessage({
            type: 'log',
            level: message.level,
            message: message.message,
            error: message.error,
            toolData: message.toolData,
        }, 'Renderer');
    }
});

//
// Initializes the worker pool and task queue for background task processing.
//
function initWorkers() {
    const workerPath = join(app.getAppPath(), 'bundle/worker.js');
    const maxWorkers = cpus().length;
    const uuidGenerator = new RandomUuidGenerator();
    const timestampProvider = new TimestampProvider();
    const taskTimeout = 600000; // 10 minutes
    const workerOptions: IWorkerPoolOptions = {
        verbose: false,
        tools: false,
        sessionId: uuidGenerator.generate(),
    };
    const electronWorkerPool = new WorkerPoolElectronMain(workerPath, maxWorkers, taskTimeout, workerOptions, (message: any) => handleWorkerLogMessage(message, 'Worker'));
    electronWorkerPool.onShowNotification((data) => {
        if (mainWindow) {
            mainWindow.webContents.send('show-notification', {
                message: data.message,
                color: data.color,
                duration: data.duration,
            });
        }
    });
    workerPool = electronWorkerPool;
    setQueueBackend(workerPool);
    console.log('Worker pool initialized');

    // Forward task completion events to renderer
    workerPool.onTaskComplete((result) => {
        if (mainWindow) {
            mainWindow.webContents.send('task-completed', {
                taskId: result.taskId,
                result
            });
        }
        if (result.type === "sync-database") {
            syncStopped();
            if (result.status !== TaskStatus.Succeeded && mainWindow) {
                mainWindow.webContents.send('sync-completed');
            }
        }
        if (result.type === "save-asset" && mainWindow) {
            const { destPath } = result.inputs as { destPath: string };
            const filename = basename(destPath);
            const folderPath = dirname(destPath);
            if (result.status === TaskStatus.Succeeded) {
                mainWindow.webContents.send('show-notification', {
                    message: `Downloaded "${filename}"`,
                    color: 'success',
                    folderPath,
                });
            }
            else {
                mainWindow.webContents.send('show-notification', {
                    message: `Failed to download "${filename}": ${result.errorMessage || 'Unknown error'}`,
                    color: 'danger',
                    duration: 8000,
                });
            }
        }
        if (result.type === "import-assets" && mainWindow) {
            if (result.status !== TaskStatus.Succeeded) {
                mainWindow.webContents.send('show-notification', {
                    message: `Import failed: ${result.errorMessage || 'Unknown error'}`,
                    color: 'danger',
                    duration: 8000,
                });
            }
        }
        if (result.type === "save-assets-batch" && mainWindow) {
            const { succeededFiles, failedFiles, folderPath } = result.outputs as { succeededFiles: string[]; failedFiles: Array<{ filename: string; error: string }>; folderPath: string };
            const total = succeededFiles.length + failedFiles.length;
            if (failedFiles.length === 0) {
                mainWindow.webContents.send('show-notification', {
                    message: `Downloaded ${total} asset${total !== 1 ? 's' : ''}`,
                    color: 'success',
                    folderPath,
                });
            }
            else if (succeededFiles.length === 0) {
                mainWindow.webContents.send('show-notification', {
                    message: `Failed to download ${total} asset${total !== 1 ? 's' : ''}`,
                    color: 'danger',
                    duration: 8000,
                });
            }
            else {
                mainWindow.webContents.send('show-notification', {
                    message: `Downloaded ${succeededFiles.length} of ${total} assets. ${failedFiles.length} failed.`,
                    color: 'warning',
                    duration: 8000,
                    folderPath,
                });
            }
        }
    });

    // Forward task messages to renderer
    workerPool.onAnyTaskMessage((data) => {
        if (mainWindow) {
            mainWindow.webContents.send('task-message', {
                taskId: data.taskId,
                message: data.message
            });
            if (data.message.type === "sync-started") {
                log.info("Sync started");
                mainWindow.webContents.send('sync-started');
            }
            else if (data.message.type === "sync-completed") {
                log.info("Sync completed");
                mainWindow.webContents.send('sync-completed');
            }
        }
    });
}

//
// Queues a sync task if a database is open and no sync is already running.
// Connectivity checking and sync-started/sync-completed messages are the worker's responsibility.
//
function enqueueSyncTask(): void {
    if (!currentDatabasePath || !workerPool || isSyncRunning) {
        return;
    }
    isSyncRunning = true;
    log.info(`Queuing sync task for ${currentDatabasePath}`);
    workerPool.addTask("sync-database", { databasePath: currentDatabasePath }, currentDatabasePath);
}

//
// Resets the isSyncRunning flag.
// Called from onTaskComplete when a sync task finishes (success, skip, or failure).
//
function syncStopped(): void {
    isSyncRunning = false;
}

//
// Cancels any running sync task for the current database, resets the running flag,
// and clears the debounce timer. Call this whenever the active database changes.
//
function resetSyncState(): void {
    if (currentDatabasePath && workerPool) {
        workerPool.cancelTasks(currentDatabasePath);
    }
    syncStopped();
    if (syncDebounceTimer !== null) {
        clearTimeout(syncDebounceTimer);
        syncDebounceTimer = null;
    }
}

//
// Schedules a debounced sync 10 seconds after the last edit notification.
// Resets the debounce timer if called again before it fires.
//
function scheduleSync(): void {
    log.info("Sync debounce triggered");
    if (syncDebounceTimer !== null) {
        clearTimeout(syncDebounceTimer);
    }
    syncDebounceTimer = setTimeout(() => {
        syncDebounceTimer = null;
        enqueueSyncTask();
    }, 10_000);
}

//
// Starts the periodic sync timer (every 5 minutes).
// The timer runs for the lifetime of the app.
// enqueueSyncTask is a no-op when no database is open or a sync is already running.
//
function startPeriodicSync(): void {
    if (syncPeriodicTimer !== null) {
        return;
    }
    syncPeriodicTimer = setInterval(() => {
        enqueueSyncTask();
    }, 5 * 60 * 1_000);
}

//
// Stops the periodic sync timer.
//
function stopPeriodicSync(): void {
    if (syncPeriodicTimer !== null) {
        clearInterval(syncPeriodicTimer);
        syncPeriodicTimer = null;
    }
}

//
// Handles log messages from a worker and forwards them to the file logger and console.
//
function handleWorkerLogMessage(message: any, source: string): void {
    if (fileLogger) {
        fileLogger.handleWorkerLogMessage(message, source);
    }
    else {
        // Fallback to console if file logger not initialized yet
        const level = message.level;
        const logMessage = message.message;
        const error = message.error;
        const toolData = message.toolData;

        switch (level) {
            case 'info':
                console.log(`[${source}] ${logMessage}`);
                break;
            case 'verbose':
                console.log(`[${source}] ${logMessage}`);
                break;
            case 'error':
                console.error(`[${source}] ${logMessage}`);
                break;
            case 'exception':
                console.error(`[${source}] ${logMessage}`);
                if (error) {
                    console.error(`[${source}] ${error}`);
                }
                break;
            case 'warn':
                console.warn(`[${source}] ${logMessage}`);
                break;
            case 'debug':
                console.debug(`[${source}] ${logMessage}`);
                break;
            case 'tool':
                if (toolData) {
                    if (toolData.stdout) {
                        console.log(`[${source}] == ${logMessage} stdout ==\n${toolData.stdout}`);
                    }
                    if (toolData.stderr) {
                        console.log(`[${source}] == ${logMessage} stderr ==\n${toolData.stderr}`);
                    }
                }
                break;
        }
    }
}

//
// Initializes the REST API server in a utility process and sets up message handlers.
//
async function initRestApi(): Promise<void> {
    // Find an available port only if we don't already have one
    // This ensures the browser window doesn't break if the worker restarts
    if (restApiPort === null) {
        const port = await findAvailablePort();
        restApiPort = port;
        console.log(`Using REST API port: ${port}`);
    }

    const serverPath = join(app.getAppPath(), 'bundle/rest-api-worker.js');

    // Set up environment for the utility process.
    // utilityProcess.fork() does not inherit process.env; pass it explicitly so Windows network stack works.
    const workerEnv: Record<string, string> = { ...process.env } as Record<string, string>;
    workerEnv.WORKER_OPTIONS = JSON.stringify({
        verbose: false,
        tools: false,
    });

    // Fork the utility process with environment
    restApiWorker = utilityProcess.fork(serverPath, [], { env: workerEnv });

    // Set up exit handler
    restApiWorker.on('exit', async (code) => {
        if (code !== 0) {
            console.error(`REST API worker exited with code ${code}`);
        }
        restApiWorker = null;

        // Restart the worker if we're not shutting down
        if (!isShuttingDown) {
            console.log('Restarting REST API worker...');
            try {
                await initRestApi();
            }
            catch (error: any) {
                console.error('Failed to restart REST API worker:', error);
            }
        }
    });

    // Wait for the server to be ready
    await new Promise<void>((resolve, reject) => {
        const timeout = setTimeout(() => {
            restApiWorker?.off('message', messageHandler);
            restApiWorker?.off('spawn', spawnHandler);
            reject(new Error('REST API failed to start within timeout'));
        }, 10000); // 10 second timeout

        const messageHandler = (message: any) => {
            if (message.type === 'server-ready') {
                clearTimeout(timeout);
                restApiWorker?.off('message', messageHandler);
                restApiWorker?.off('spawn', spawnHandler);
                console.log(`REST API initialized in utility process on port ${restApiPort}`);
                resolve();
            }
            else if (message.type === 'server-error') {
                clearTimeout(timeout);
                restApiWorker?.off('message', messageHandler);
                restApiWorker?.off('spawn', spawnHandler);
                console.error('REST API error:', message.error);
                reject(new Error(`REST API failed to start: ${message.error}`));
            }
            else if (message.type === 'server-stopped') {
                console.log('REST API stopped');
            }
            else if (message.type === 'log') {
                // Handle log messages from worker
                handleWorkerLogMessage(message, 'REST API Worker');
            }
        };

        const spawnHandler = () => {
            console.log('REST API utility process spawned');
            // Send start message to the utility process with the port
            // restApiPort should never be null here since we set it above
            if (restApiWorker && restApiPort !== null) {
                const startMessage: IRestApiWorkerStartMessage = { 
                    type: 'start', 
                    port: restApiPort,
                };
                restApiWorker.postMessage(startMessage);
            }
        };

        if (!restApiWorker) {
            reject(new Error('Failed to fork REST API utility process'));
            return;
        }

        restApiWorker.on('message', messageHandler);
        restApiWorker.on('spawn', spawnHandler);
    });

    // Set up persistent log message handler (not just for startup)
    restApiWorker.on('message', (message: any) => {
        if (message.type === 'log') {
            handleWorkerLogMessage(message, 'REST API Worker');
        }
    });
}

//
// Shows a directory picker dialog, focusing the main window first if available.
// Returns the selected path, or undefined if the user cancelled.
//
async function showDirectoryPicker(title: string, extraProperties: Electron.OpenDialogOptions['properties'] = []): Promise<string | undefined> {
    if (mainWindow) {
        if (mainWindow.isMinimized()) {
            mainWindow.restore();
        }
        mainWindow.focus();
    }

    const config = await loadDesktopConfig();
    const options: Electron.OpenDialogOptions = {
        properties: ['openDirectory', ...extraProperties],
        title,
        defaultPath: config.lastFolder,
    };
    const result = mainWindow
        ? await dialog.showOpenDialog(mainWindow, options)
        : await dialog.showOpenDialog(options);

    if (result.canceled || result.filePaths.length === 0) {
        return undefined;
    }

    return result.filePaths[0];
}

//
// Opens a file dialog for the user to select a database directory, then notifies the frontend.
// The REST API can handle multiple databases dynamically via the db query parameter.
//
async function openDatabase(): Promise<void> {
    const databasePath = await showDirectoryPicker('Open Database');
    if (!databasePath) {
        return;
    }

    await updateLastFolder(dirname(databasePath));

    // Notify frontend to load the database
    // The REST API doesn't need to be restarted since it handles multiple databases dynamically
    if (mainWindow) {
        mainWindow.webContents.send('database-opened', databasePath);
        // Menu will be updated when frontend calls notifyDatabaseOpened()
    }
}

//
// Creates a new database by showing a directory picker, dispatching initialization
// to the task worker, then notifying the frontend to open the result.
//
async function createNewDatabase(): Promise<void> {
    const databasePath = await showDirectoryPicker('Create Database', ['createDirectory']);
    if (!databasePath) {
        return;
    }

    if (!workerPool) {
        throw new Error('Worker pool not initialized');
    }

    const uuidGenerator = new RandomUuidGenerator();
    const createQueue = new TaskQueue(uuidGenerator, databasePath);
    const taskId = randomUUID();
    createQueue.addTask('create-database', { databasePath }, taskId);
    await createQueue.awaitTask(taskId);
    createQueue.shutdown();

    await updateLastFolder(dirname(databasePath));

    if (mainWindow) {
        mainWindow.webContents.send('database-opened', databasePath);
    }
}

//
// Shows a folder picker and queues an add-paths task to import assets from the chosen directory.
// Returns session info so the renderer can track progress and cancel, or undefined if the user
// cancelled the folder picker.
//
//
// Starts an import session for the given paths (files or directories).
// Returns session info for progress tracking, or undefined if no database is open.
//
async function startImportWithPaths(paths: string[]): Promise<IImportSession | undefined> {
    if (!currentDatabasePath) {
        return undefined;
    }

    if (!workerPool) {
        throw new Error('Worker pool not initialized');
    }

    const storageDescriptor: IDatabaseDescriptor = {
        databasePath: currentDatabasePath,
    };

    const sessionId = randomUUID();
    const importAssetsTaskId = workerPool.addTask('add-paths', {
        paths,
        storageDescriptor,
        sessionId,
        dryRun: false,
    }, sessionId);

    return { importAssetsTaskId, sessionId };
}

//
// Imports assets from the given paths, or shows a directory picker when no paths are supplied.
// Returns session info for progress tracking, or undefined if no database is open or the user cancelled.
//
async function selectAndImportAssets(paths?: string[]): Promise<IImportSession | undefined> {
    if (!currentDatabasePath) {
        return undefined;
    }

    if (paths && paths.length > 0) {
        return startImportWithPaths(paths);
    }

    const selectedPath = await showDirectoryPicker('Import Assets');
    if (!selectedPath) {
        return undefined;
    }

    return startImportWithPaths([selectedPath]);
}

//
// Closes the currently open database.
//
async function closeDatabase(): Promise<void> {
    if (mainWindow) {
        // Notify frontend to close the database.
        // This sends a message back to the main process to update the state here.
        mainWindow.webContents.send('database-closed');
    }
}

//
// Creates the application menu bar with standard menu items for macOS, Windows, and Linux.
//
async function createMenu(): Promise<void> {
    const isMac = process.platform === 'darwin';
    const template: Electron.MenuItemConstructorOptions[] = [];
    const currentTheme = await getTheme();

    // macOS App Menu (first menu on macOS)
    if (isMac) {
        template.push({
            label: app.getName(),
            submenu: [
                {
                    label: `About Photosphere`,
                    click: async () => {
                        if (mainWindow) {
                            mainWindow.webContents.executeJavaScript('window.location.hash = "/about"');
                        }
                    },
                },
                { type: 'separator' },
                { role: 'services', submenu: [] },
                { type: 'separator' },
                { role: 'hide', label: `Hide Photosphere` },
                { role: 'hideOthers' },
                { role: 'unhide' },
                { type: 'separator' },
                { role: 'quit', label: `Quit Photosphere` },
            ],
        });
    }

    // File Menu
    const fileSubmenu: Electron.MenuItemConstructorOptions[] = [
        {
            label: 'New Database...',
            accelerator: 'CmdOrCtrl+N',
            click: () => {
                if (mainWindow) {
                    mainWindow.webContents.send('menu-action', 'new-database');
                }
            },
        },
        {
            label: 'Open Database...',
            accelerator: 'CmdOrCtrl+O',
            click: () => {
                if (mainWindow) {
                    mainWindow.webContents.send('menu-action', 'open-database');
                }
            },
        },
    ];

    // Add Import Assets and Close Database menu items if a database is open
    if (isDatabaseOpen) {
        fileSubmenu.push(
            { type: 'separator' },
            {
                label: 'Import Assets...',
                accelerator: 'CmdOrCtrl+I',
                click: logExceptions(() => selectAndImportAssets(), 'Error importing assets from menu'),
            },
            { type: 'separator' },
            {
                label: 'Close Database',
                click: logExceptions(closeDatabase, 'Error closing database from menu'),
            }
        );
    }


    // Add Exit/Quit to File menu on Windows/Linux
    if (!isMac) {
        fileSubmenu.push(
            { type: 'separator' },
            { role: 'quit', label: 'Exit' }
        );
    }

    template.push({
        label: 'File',
        submenu: fileSubmenu,
    });

    // View Menu
    const viewSubmenu: Electron.MenuItemConstructorOptions[] = [
        {
            label: 'Gallery',
            click: () => {
                if (mainWindow) {
                    mainWindow.webContents.send('navigate', '/gallery');
                }
            },
        },
        {
            label: 'Map',
            click: () => {
                if (mainWindow) {
                    mainWindow.webContents.send('navigate', '/map');
                }
            },
        },
        {
            label: 'Import',
            click: () => {
                if (mainWindow) {
                    mainWindow.webContents.send('navigate', '/import');
                }
            },
        },
        {
            label: 'About',
            click: () => {
                if (mainWindow) {
                    mainWindow.webContents.send('navigate', '/about');
                }
            },
        },
        { type: 'separator' },
        { role: 'resetZoom', label: 'Actual Size' },
        { role: 'zoomIn', label: 'Zoom In' },
        { role: 'zoomOut', label: 'Zoom Out' },
        { type: 'separator' },
        { role: 'togglefullscreen', label: 'Toggle Fullscreen' },
    ];

    template.push({
        label: 'View',
        submenu: viewSubmenu,
    });

    // Preferences Menu
    template.push({
        label: 'Preferences',
        submenu: [
            {
                label: 'Theme',
                submenu: [
                    {
                        label: 'Light',
                        type: 'radio',
                        checked: currentTheme === 'light',
                        click: async () => {
                            await setTheme('light');
                            if (mainWindow) {
                                mainWindow.webContents.send('theme-changed', 'light');
                            }
                            await updateMenu();
                        },
                    },
                    {
                        label: 'Dark',
                        type: 'radio',
                        checked: currentTheme === 'dark',
                        click: async () => {
                            await setTheme('dark');
                            if (mainWindow) {
                                mainWindow.webContents.send('theme-changed', 'dark');
                            }
                            await updateMenu();
                        },
                    },
                    {
                        label: 'System',
                        type: 'radio',
                        checked: currentTheme === 'system',
                        click: async () => {
                            await setTheme('system');
                            if (mainWindow) {
                                mainWindow.webContents.send('theme-changed', 'system');
                            }
                            await updateMenu();
                        },
                    },
                ],
            },
            { type: 'separator' },
            {
                label: 'Manage Databases',
                click: () => {
                    if (mainWindow) {
                        mainWindow.webContents.send('navigate', '/databases');
                    }
                },
            },
            {
                label: 'Manage Secrets',
                click: () => {
                    if (mainWindow) {
                        mainWindow.webContents.send('navigate', '/secrets');
                    }
                },
            },
            { type: 'separator' },
            {
                label: 'Configuration...',
                click: () => {
                    if (mainWindow) {
                        mainWindow.webContents.send('menu-action', 'open-configuration');
                    }
                },
            },
        ],
    });

    // Window Menu
    const windowSubmenu: Electron.MenuItemConstructorOptions[] = [
        { role: 'minimize', label: 'Minimize' },
        { role: 'zoom', label: 'Zoom' },
    ];

    if (isMac) {
        windowSubmenu.push(
            { type: 'separator' },
            { role: 'front', label: 'Bring All to Front' }
        );
    }
    else {
        windowSubmenu.push(
            { type: 'separator' },
            { role: 'close', label: 'Close' }
        );
    }

    template.push({
        label: 'Window',
        submenu: windowSubmenu,
    });

    // Developer Menu
    const developerSubmenu: Electron.MenuItemConstructorOptions[] = [
        { role: 'reload', label: 'Reload' },
        { role: 'forceReload', label: 'Force Reload' },
        { role: 'toggleDevTools', label: 'Toggle Developer Tools' },
    ];

    template.push({
        label: 'Developer',
        submenu: developerSubmenu,
    });

    // Help Menu
    const helpSubmenu: Electron.MenuItemConstructorOptions[] = [
        {
            label: `About Photosphere`,
            click: async () => {
                if (mainWindow) {
                    mainWindow.webContents.executeJavaScript('window.location.hash = "/about"');
                }
            },
        },
        { type: 'separator' },
        {
            label: `Photosphere Help`,
            click: async () => {
                await shell.openExternal('https://github.com/ashleydavis/photosphere/wiki');
            },
        },
        { type: 'separator' },
        {
            label: 'Open Log Directory',
            click: async () => {
                if (fileLogger) {
                    const logsDir = fileLogger.getLogsDirectory();
                    await shell.openPath(logsDir);
                }
            },
        },
        { type: 'separator' },
        {
            label: 'Report Bug...',
            click: async () => {
                await openBugReport();
            },
        },
    ];

    template.push({
        role: 'help',
        label: 'Help',
        submenu: helpSubmenu,
    });

    const menu = Menu.buildFromTemplate(template);
    Menu.setApplicationMenu(menu);
}

//
// Updates the application menu (useful when database state changes).
//
async function updateMenu(): Promise<void> {
    await createMenu();
}

//
// Gets the path to the latest log file.
//
function getLatestLogFile(): string | null {
    try {
        const logsDir = fileLogger?.getLogsDirectory();
        if (!logsDir || !existsSync(logsDir)) {
            return null;
        }
        
        const logFiles = readdirSync(logsDir)
            .filter(file => file.startsWith('photosphere-') && file.endsWith('.log') && !file.includes('-errors'))
            .map(file => ({
                name: file,
                path: join(logsDir, file),
                mtime: statSync(join(logsDir, file)).mtime
            }))
            .sort((a, b) => b.mtime.getTime() - a.mtime.getTime());
        
        return logFiles.length > 0 ? logFiles[0].path : null;
    }
    catch (error) {
        return null;
    }
}

//
// Gets the header section of a log file (everything up to "--- Log Start ---").
//
function getLogHeader(logFilePath: string | null): string {
    if (!logFilePath || !existsSync(logFilePath)) {
        return 'No log file available';
    }
    
    try {
        const logContent = readFileSync(logFilePath, 'utf8');
        const logStartIndex = logContent.indexOf('--- Log Start ---');
        
        if (logStartIndex === -1) {
            // If no "--- Log Start ---" marker found, return first 50 lines
            const lines = logContent.split('\n');
            return lines.slice(0, 50).join('\n');
        }
        
        // Return everything up to (and including) the "--- Log Start ---" line
        const headerContent = logContent.substring(0, logStartIndex + '--- Log Start ---'.length);
        return headerContent;
    }
    catch (error) {
        return `Error reading log file: ${error instanceof Error ? error.message : 'Unknown error'}`;
    }
}

//
// Generates the bug report template for GitHub.
//
function generateBugReportTemplate(): string {
    const latestLogFile = getLatestLogFile();
    const logHeader = getLogHeader(latestLogFile);
    
    return `## Bug Description
<!-- Please describe the bug you encountered -->

## Steps to Reproduce
1. 
2. 
3. 

## Expected Behavior
<!-- What did you expect to happen? -->

## Actual Behavior
<!-- What actually happened? -->

## System Information
- Application: Photosphere Desktop
- Platform: ${platform()} ${arch()}
- OS Release: ${release()}
- Electron: ${process.versions.electron || 'unknown'}
- Chrome: ${process.versions.chrome || 'unknown'}
- Node.js: ${process.version}

## Log Header
\`\`\`
${logHeader}
\`\`\`

## Log File
Please attach the full log file located at:
\`${latestLogFile || 'No log file available'}\`

You can drag and drop the log file into this issue, or copy and paste its contents into a code block.

## Additional Context
<!-- Add any other context about the problem here -->

`;
}

//
// Creates a GitHub issue URL with the bug report template pre-filled.
//
function createGitHubIssueUrl(title: string, body: string): string {
    const baseUrl = 'https://github.com/ashleydavis/photosphere/issues/new';
    const params = new URLSearchParams({
        title: title,
        body: body,
        labels: 'bug'
    });
    
    return `${baseUrl}?${params.toString()}`;
}

//
// Opens a bug report in the default browser.
//
async function openBugReport(): Promise<void> {
    const template = generateBugReportTemplate();
    const url = createGitHubIssueUrl('Bug Report', template);
    await shell.openExternal(url);
}

//
// Handle uncaught exceptions in the main process
//
process.on('uncaughtException', (error) => {
    if (fileLogger) {
        fileLogger.exception('Uncaught exception in main process', error);
    }
    else {
        console.error('Uncaught exception in main process:', error);
    }
});

//
// Handle unhandled promise rejections in the main process
//
process.on('unhandledRejection', (reason, promise) => {
    const error = reason instanceof Error ? reason : new Error(String(reason));
    if (fileLogger) {
        fileLogger.exception('Unhandled rejection in main process', error);
    }
    else {
        console.error('Unhandled rejection in main process:', error);
    }
});

