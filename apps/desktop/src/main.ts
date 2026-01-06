import { app, BrowserWindow, ipcMain } from 'electron';
import { join } from 'path';
import { tmpdir } from 'node:os';
import { cpus } from 'os';
import type { ITaskQueue } from 'task-queue';
import { TaskQueueElectronMain } from './task-queue-electron-main';
import { RandomUuidGenerator, TimestampProvider } from 'utils';

let mainWindow: BrowserWindow | null = null;
let taskQueue: ITaskQueue | null = null;

function createMainWindow() {
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
    const htmlPath = join(__dirname, '../bundle/frontend/index.html');
    mainWindow.loadFile(htmlPath);
    
    // Open dev tools in development
    if (process.env.NODE_ENV === 'development' || !app.isPackaged) {
        mainWindow.webContents.openDevTools();
    }

    mainWindow.on('closed', () => {
        mainWindow = null;
    });
}

app.whenReady().then(() => {
    createMainWindow();

    app.on('activate', () => {
        if (BrowserWindow.getAllWindows().length === 0) {
            createMainWindow();
        }
    });

    initWorkers();
});

app.on('window-all-closed', () => {
    if (process.platform !== 'darwin') {
        app.quit();
    }
});

app.on('before-quit', () => {
    // Cleanup task queue
    if (taskQueue) {
        taskQueue.shutdown();
        taskQueue = null;
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

//
// Initialize the worker pool and task queue.
//
function initWorkers() {
    const workerPath = join(__dirname, '../bundle/worker.js');
    const maxWorkers = cpus().length;
    const baseWorkingDirectory = join(tmpdir(), "photosphere-electron-task-queue");
    const uuidGenerator = new RandomUuidGenerator();
    const timestampProvider = new TimestampProvider();
    const taskTimeout = 600000; // 10 minutes
    const workerOptions = {
        verbose: false,
        tools: false,
        sessionId: uuidGenerator.generate(),
    };
    taskQueue = new TaskQueueElectronMain(workerPath, maxWorkers, baseWorkingDirectory, uuidGenerator, timestampProvider, taskTimeout, workerOptions);
    console.log('Task queue initialized');

    // Forward task completion events to renderer
    taskQueue.onTaskComplete((result) => {
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

