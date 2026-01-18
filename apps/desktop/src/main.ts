import { app, BrowserWindow, ipcMain, utilityProcess, type UtilityProcess, dialog, Menu } from 'electron';
import { join, dirname } from 'path';
import { cpus } from 'os';
import type { ITask, ITaskQueue, IWorkerBackend } from 'task-queue';
import { TaskQueue } from 'task-queue';
import { WorkerBackendElectronMain } from './lib/worker-backend-electron-main';
import { RandomUuidGenerator, TimestampProvider, logExceptions } from 'utils';
import { findAvailablePort, loadDesktopConfig, addRecentDatabase, removeRecentDatabase, updateLastFolder } from 'node-utils';
import type { IWorkerOptions } from './lib/worker-init';
import type { IRestApiWorkerStopMessage, IRestApiWorkerStartMessage } from './rest-api-worker';

let mainWindow: BrowserWindow | null = null;
let taskQueue: ITaskQueue | null = null;
let workerBackend: IWorkerBackend | null = null;
let restApiWorker: UtilityProcess | null = null;
let isShuttingDown: boolean = false;
let restApiPort: number | null = null;

//
// Creates and configures the main browser window for the Electron app.
//
function createMainWindow() {
    if (restApiPort === null) {
        throw new Error('REST API port not initialized');
    }

    mainWindow = new BrowserWindow({
        width: 1200,
        height: 800,
        webPreferences: {
            nodeIntegration: false,
            contextIsolation: true,
            preload: join(__dirname, '../bundle/preload.js'),
        },
    });

    // Load from built frontend (works in both dev and production)
    // Pass restApiUrl as query parameter so the frontend can use it
    const htmlPath = join(__dirname, '../bundle/frontend/index.html');
    const restApiUrl = `http://localhost:${restApiPort}`;
    const fileUrl = `file://${htmlPath}?restApiUrl=${encodeURIComponent(restApiUrl)}`;
    mainWindow.loadURL(fileUrl);
    
    // Open dev tools in development
    if (process.env.NODE_ENV === 'development' || !app.isPackaged) {
        mainWindow.webContents.openDevTools();
    }

    mainWindow.on('closed', () => {
        mainWindow = null;
    });
}

app.whenReady().then(async () => {
    // Initialize REST API before creating main window
    await initRestApi();

    // Create application menu
    createMenu();
    
    // Start up the background workers
    initWorkers();
    
    createMainWindow();

    app.on('activate', () => {
        if (BrowserWindow.getAllWindows().length === 0) {
            createMainWindow();
        }
    });
});

app.on('window-all-closed', () => {
    if (process.platform !== 'darwin') {
        app.quit();
    }
});

app.on('before-quit', () => {
    isShuttingDown = true;
    
    // Cleanup task queue
    if (taskQueue) {
        taskQueue.shutdown();
        taskQueue = null;
    }
    
    // Cleanup worker backend
    if (workerBackend) {
        workerBackend.shutdown();
        workerBackend = null;
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
});

// IPC handler for adding tasks
ipcMain.on('add-task', (event, taskType: string, data: any, taskId?: string) => {
    if (!taskQueue) {
        console.error('Task queue not initialized');
        return;
    }
    
    taskQueue.addTask(taskType, data, taskId);
});

// IPC handler for opening file dialog
// Note: ipcMain.handle automatically catches errors from async functions and sends them to the renderer.
// If the handler throws or returns a rejected promise, Electron serializes the error and sends it to the renderer.
// The renderer can catch it when calling ipcRenderer.invoke().
ipcMain.handle('open-file', logExceptions(openDatabase, 'Error opening database'));

// IPC handler for removing a database from recent list
ipcMain.handle('remove-database', logExceptions(async (event, databasePath: string) => {
    await removeRecentDatabase(databasePath);
    return { success: true };
}, 'Error removing database'));

// IPC handler for getting recent databases list
ipcMain.handle('get-recent-databases', logExceptions(async () => {
    const config = await loadDesktopConfig();
    return config.recentDatabases || [];
}, 'Error getting recent databases'));

// IPC handler for adding a database to recent list
ipcMain.handle('add-recent-database', logExceptions(async (event, databasePath: string) => {
    await addRecentDatabase(databasePath);
    return { success: true };
}, 'Error adding recent database'));

//
// Initializes the worker pool and task queue for background task processing.
//
function initWorkers() {
    const workerPath = join(__dirname, '../bundle/worker.js');
    const maxWorkers = cpus().length;
    const uuidGenerator = new RandomUuidGenerator();
    const timestampProvider = new TimestampProvider();
    const taskTimeout = 600000; // 10 minutes
    const workerOptions: IWorkerOptions = {
        verbose: false,
        tools: false,
        sessionId: uuidGenerator.generate(),
    };
    workerBackend = new WorkerBackendElectronMain(workerPath, maxWorkers, taskTimeout, workerOptions);
    taskQueue = new TaskQueue(uuidGenerator, timestampProvider, taskTimeout, workerBackend);
    console.log('Task queue initialized');

    // Forward task completion events to renderer
    taskQueue.onTaskComplete<ITask<any>, any>((task, result) => {
        if (mainWindow) {
            mainWindow.webContents.send('task-completed', {
                taskId: result.taskId,
                result
            });
        }
    });

    // Forward task messages to renderer
    taskQueue.onAnyTaskMessage((data) => {
        if (mainWindow) {
            mainWindow.webContents.send('task-message', {
                taskId: data.taskId,
                message: data.message
            });
        }
    });
}

//
// Handles log messages from the REST API worker and forwards them to the main process console.
//
function handleWorkerLogMessage(message: any): void {
    const level = message.level;
    const logMessage = message.message;
    const error = message.error;
    const toolData = message.toolData;

    switch (level) {
        case 'info':
            console.log(`[REST API] ${logMessage}`);
            break;
        case 'verbose':
            console.log(`[REST API] ${logMessage}`);
            break;
        case 'error':
            console.error(`[REST API] ${logMessage}`);
            break;
        case 'exception':
            console.error(`[REST API] ${logMessage}`);
            if (error) {
                console.error(`[REST API] ${error}`);
            }
            break;
        case 'warn':
            console.warn(`[REST API] ${logMessage}`);
            break;
        case 'debug':
            console.debug(`[REST API] ${logMessage}`);
            break;
        case 'tool':
            if (toolData) {
                if (toolData.stdout) {
                    console.log(`[REST API] == ${logMessage} stdout ==\n${toolData.stdout}`);
                }
                if (toolData.stderr) {
                    console.log(`[REST API] == ${logMessage} stderr ==\n${toolData.stderr}`);
                }
            }
            break;
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

    const serverPath = join(__dirname, '../bundle/rest-api-worker.js');

    // Fork the utility process
    restApiWorker = utilityProcess.fork(serverPath);

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
                handleWorkerLogMessage(message);
            }
        };

        const spawnHandler = () => {
            console.log('REST API utility process spawned');
            // Send start message to the utility process with the port
            // restApiPort should never be null here since we set it above
            if (restApiWorker && restApiPort !== null) {
                const startMessage: IRestApiWorkerStartMessage = { type: 'start', port: restApiPort };
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
            handleWorkerLogMessage(message);
        }
    });
}

//
// Opens a file dialog for the user to select a database directory, then notifies the frontend.
// The REST API can handle multiple databases dynamically via the db query parameter.
//
async function openDatabase(): Promise<void> {
    // Ensure main window is focused before showing modal dialog
    if (mainWindow) {
        if (mainWindow.isMinimized()) {
            mainWindow.restore();
        }
        mainWindow.focus();
    }

    // Load config to get last folder
    const config = await loadDesktopConfig();

    // Show file dialog to select database (modal when mainWindow is provided)
    const result = mainWindow
        ? await dialog.showOpenDialog(mainWindow, {
            properties: ['openDirectory'],
            title: 'Open Database',
            defaultPath: config.lastFolder,
        })
        : await dialog.showOpenDialog({
            properties: ['openDirectory'],
            title: 'Open Database',
            defaultPath: config.lastFolder,
        });

    if (result.canceled || result.filePaths.length === 0) {
        return;
    }

    const databasePath = result.filePaths[0];

    // Save to recent databases and update last folder
    await addRecentDatabase(databasePath);
    const folderPath = dirname(databasePath);
    await updateLastFolder(folderPath);

    // Notify frontend to load the database
    // The REST API doesn't need to be restarted since it handles multiple databases dynamically
    if (mainWindow) {
        mainWindow.webContents.send('database-opened', databasePath);
    }
}

//
// Creates the application menu bar with File menu and Open Database option.
//
function createMenu(): void {
    const template: Electron.MenuItemConstructorOptions[] = [
        {
            label: 'File',
            submenu: [
                {
                    label: 'Open Database...',
                    accelerator: 'CmdOrCtrl+O',
                    click: logExceptions(openDatabase, 'Error opening database from menu'),
                },
            ],
        },
    ];

    const menu = Menu.buildFromTemplate(template);
    Menu.setApplicationMenu(menu);
}

