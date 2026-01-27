import { app, BrowserWindow, ipcMain, utilityProcess, type UtilityProcess, dialog, Menu, shell } from 'electron';
import { join, dirname } from 'path';
import { cpus, platform, arch, release } from 'os';
import { existsSync, readdirSync, statSync, readFileSync } from 'fs';
import type { ITask, ITaskQueue, IWorkerBackend } from 'task-queue';
import { TaskQueue } from 'task-queue';
import { WorkerBackendElectronMain } from './lib/worker-backend-electron-main';
import { RandomUuidGenerator, TimestampProvider, logExceptions } from 'utils';
import { findAvailablePort, loadDesktopConfig, addRecentDatabase, removeRecentDatabase, updateLastFolder, clearLastDatabase, getTheme, setTheme } from 'node-utils';
import type { IWorkerOptions } from './lib/worker-init';
import type { IRestApiWorkerStopMessage, IRestApiWorkerStartMessage } from './rest-api-worker';
import { FileLoggerElectron } from './lib/file-logger-electron';
import type { IRendererLogMessage } from 'electron-defs';

// Main application window
let mainWindow: BrowserWindow | null = null;

// Task queue for background task processing
let taskQueue: ITaskQueue | null = null;

// Worker backend for executing tasks
let workerBackend: IWorkerBackend | null = null;

// REST API utility process
let restApiWorker: UtilityProcess | null = null;

// Flag to prevent restarting workers during shutdown
let isShuttingDown: boolean = false;

// Port number for the REST API server
let restApiPort: number | null = null;

// Tracks whether a database is currently open (used for menu state)
let isDatabaseOpen: boolean = false;

// File logger for writing logs to files
let fileLogger: FileLoggerElectron | null = null;

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
        webPreferences: {
            nodeIntegration: false,
            contextIsolation: true,
            preload: join(app.getAppPath(), 'bundle/preload.js'),
        },
    });

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
    
    if (fileLogger) {
        fileLogger.info('Photosphere Desktop shutting down...', 'Main');
    }
    
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
    
    // Close file logger last to capture all shutdown logs
    if (fileLogger) {
        await fileLogger.close();
        fileLogger = null;
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
}, 'Error removing database'));

// IPC handler for getting recent databases list
ipcMain.handle('get-recent-databases', logExceptions(async () => {
    const config = await loadDesktopConfig();
    return config.recentDatabases || [];
}, 'Error getting recent databases'));

// IPC handler for notifying that database was opened from frontend
ipcMain.handle('notify-database-opened', logExceptions(async (event, databasePath: string) => {
    await addRecentDatabase(databasePath);
    isDatabaseOpen = true;
    await updateMenu();
}, 'Error notifying database opened'));

// IPC handler for notifying that database was closed from frontend
ipcMain.handle('notify-database-closed', logExceptions(async () => {
    await clearLastDatabase();
    isDatabaseOpen = false;
    await updateMenu();
}, 'Error notifying database closed'));

// IPC handler for getting theme preference
ipcMain.handle('get-theme', logExceptions(async () => {
    return await getTheme();
}, 'Error getting theme'));

// IPC handler for setting theme preference
ipcMain.handle('set-theme', logExceptions(async (event, theme: 'light' | 'dark' | 'system') => {
    await setTheme(theme);
    // Notify frontend of theme change
    if (mainWindow) {
        mainWindow.webContents.send('theme-changed', theme);
    }
}, 'Error setting theme'));

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
// Handles log messages from the REST API worker and forwards them to the file logger and console.
//
function handleWorkerLogMessage(message: any, source: string = 'REST API'): void {
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
        // Menu will be updated when frontend calls notifyDatabaseOpened()
    }
}

//
// Closes the currently open database.
//
async function closeDatabase(): Promise<void> {
    if (mainWindow) {
        // Notify frontend to close the database
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
            label: 'Open Database...',
            accelerator: 'CmdOrCtrl+O',
            click: logExceptions(openDatabase, 'Error opening database from menu'),
        },
    ];

    // Add Close Database menu item if a database is open
    if (isDatabaseOpen) {
        fileSubmenu.push(
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

