import { app, BrowserWindow, ipcMain, utilityProcess, type UtilityProcess, dialog, Menu } from 'electron';
import { join } from 'path';
import { cpus } from 'os';
import type { ITask, ITaskQueue } from 'task-queue';
import { TaskQueue } from 'task-queue';
import { WorkerBackendElectronMain } from './lib/worker-backend-electron-main';
import { RandomUuidGenerator, TimestampProvider } from 'utils';
import { findAvailablePort } from 'node-utils';
import type { IWorkerOptions } from './lib/worker-init';
import type { IRestApiWorkerStopMessage, IRestApiWorkerStartMessage } from './rest-api-worker';

let mainWindow: BrowserWindow | null = null;
let taskQueue: ITaskQueue | null = null;
let restApiWorker: UtilityProcess | null = null;
let isShuttingDown: boolean = false;
let restApiPort: number | null = null;

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
    
    // Start up the backgorund workers
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
ipcMain.handle('open-file', async () => {
    await openDatabase();
});

//
// Initialize the worker pool and task queue.
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
    const workerBackend = new WorkerBackendElectronMain(workerPath, maxWorkers, taskTimeout, workerOptions);
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
// Initialize the rest api in a utility process.
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
}

//
// Opens a database file dialog, lets the user select a database, and notifies the frontend.
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

    // Show file dialog to select database (modal when mainWindow is provided)
    const result = mainWindow
        ? await dialog.showOpenDialog(mainWindow, {
            properties: ['openDirectory'],
            title: 'Open Database',
        })
        : await dialog.showOpenDialog({
            properties: ['openDirectory'],
            title: 'Open Database',
        });

    if (result.canceled || result.filePaths.length === 0) {
        return;
    }

    const databasePath = result.filePaths[0];

    // Notify frontend to load the database
    // The REST API doesn't need to be restarted since it handles multiple databases dynamically
    if (mainWindow) {
        mainWindow.webContents.send('database-opened', databasePath);
    }
}

//
// Creates the application menu.
//
function createMenu(): void {
    const template: Electron.MenuItemConstructorOptions[] = [
        {
            label: 'File',
            submenu: [
                {
                    label: 'Open Database...',
                    accelerator: 'CmdOrCtrl+O',
                    click: async () => {
                        await openDatabase();
                    },
                },
            ],
        },
    ];

    const menu = Menu.buildFromTemplate(template);
    Menu.setApplicationMenu(menu);
}

