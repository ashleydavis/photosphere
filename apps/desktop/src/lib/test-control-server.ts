import express from 'express';
import type { Express } from 'express';
import http from 'http';
import { app, BrowserWindow, ipcMain } from 'electron';
import { log } from 'utils';
import { TestUuidGenerator } from 'node-utils';
import { TaskQueue, TaskStatus } from 'task-queue';
import type { IQueueBackend } from 'task-queue';

//
// Interface for the HTTP test control server started in test mode.
//
export interface ITestControlServer {
    // Signals that the main window has finished loading.
    notifyReady(): void;
    // Shuts down the HTTP server.
    close(): void;
}

//
// HTTP test control server that allows shell scripts to drive the Electron app programmatically.
// Only started when PHOTOSPHERE_TEST_MODE=1. Listens on the port given by PHOTOSPHERE_TEST_PORT.
//
export class TestControlServer implements ITestControlServer {
    //
    // Whether the main window has signalled it is ready.
    //
    private isReady: boolean = false;

    //
    // Reference to the main Electron window for sending IPC messages.
    //
    private mainWindow: BrowserWindow;

    //
    // Worker pool used to queue tasks (create-database, add-paths) on behalf of tests.
    //
    private workerPool: IQueueBackend;

    //
    // Returns the path of the currently open database, or null when none. Used by the
    // import-assets endpoint so it can target the active database without holding stale state.
    //
    private getCurrentDatabasePath: () => string | null;

    //
    // The underlying HTTP server instance.
    //
    private server: http.Server;

    constructor(mainWindow: BrowserWindow, workerPool: IQueueBackend, getCurrentDatabasePath: () => string | null) {
        this.mainWindow = mainWindow;
        this.workerPool = workerPool;
        this.getCurrentDatabasePath = getCurrentDatabasePath;

        const expressApp: Express = express();
        expressApp.use(express.json());

        expressApp.get('/ready', (_req, res) => {
            if (this.isReady) {
                res.json({ ok: true });
            }
            else {
                res.status(503).json({ ok: false, error: 'Not ready yet' });
            }
        });

        expressApp.post('/navigate', (req, res) => {
            const page: string = req.body.page.startsWith('/') ? req.body.page : `/${req.body.page}`;
            this.mainWindow.webContents.send('navigate', page);
            log.info(`Navigated to ${page}`);
            res.json({ ok: true });
        });

        expressApp.post('/menu', (req, res) => {
            this.mainWindow.webContents.send('menu-action', req.body.itemId);
            res.json({ ok: true });
        });

        expressApp.post('/click', (req, res) => {
            this.mainWindow.webContents.send('test-click', { dataId: req.body.dataId, nth: req.body.nth });
            res.json({ ok: true });
        });

        expressApp.post('/long-press-click', (req, res) => {
            this.mainWindow.webContents.send('test-long-press-click', { dataId: req.body.dataId, nth: req.body.nth });
            res.json({ ok: true });
        });

        expressApp.post('/type', (req, res) => {
            this.mainWindow.webContents.send('test-type', { dataId: req.body.dataId, text: req.body.text });
            res.json({ ok: true });
        });

        expressApp.post('/create-database', async (req, res) => {
            const databasePath: string = req.body.path;
            const queue = new TaskQueue(new TestUuidGenerator(), databasePath);
            try {
                const taskId = queue.addTask('create-database', { databasePath });
                const result = await queue.awaitTask(taskId);
                if (!result || result.status !== TaskStatus.Succeeded) {
                    throw new Error(`create-database task failed: ${result?.errorMessage || 'unknown error'}`);
                }
            }
            finally {
                queue.shutdown();
            }
            log.event(`Database created: ${databasePath}`);
            this.mainWindow.webContents.send('database-opened', databasePath);
            res.json({ ok: true });
        });

        expressApp.post('/open-database', (req, res) => {
            this.mainWindow.webContents.send('database-opened', req.body.path);
            res.json({ ok: true });
        });

        expressApp.post('/drop', (req, res) => {
            this.mainWindow.webContents.send('test-drop', { dataId: req.body.dataId, paths: req.body.paths });
            res.json({ ok: true });
        });

        expressApp.get('/get-value', async (req, res) => {
            const dataId = req.query.dataId as string;
            const value = await this.mainWindow.webContents.executeJavaScript(`
                (() => {
                    const el = document.querySelector('[data-id="${dataId}"]');
                    return el ? (el.value || el.textContent || '') : '';
                })()
            `);
            res.json({ ok: true, value });
        });

        expressApp.post('/import-assets', (req, res) => {
            const databasePath = this.getCurrentDatabasePath();
            if (databasePath) {
                const sessionId = new TestUuidGenerator().generate();
                this.workerPool.addTask('add-paths', {
                    paths: req.body.paths,
                    storageDescriptor: { databasePath },
                    sessionId,
                    dryRun: false,
                }, sessionId);
            }
            res.json({ ok: true });
        });

        expressApp.post('/data', (req, res) => {
            const body = req.body;
            if (!body || Object.keys(body).length === 0) {
                res.status(400).json({ error: 'Request body is empty' });
                return;
            }
            console.log('Received:', body);
            res.status(200).json({ message: 'Data received successfully', received: body });
        });

        expressApp.post('/quit', (_req, res) => {
            res.json({ ok: true });
            app.quit();
        });

        this.server = http.createServer(expressApp);
    }

    //
    // Starts the HTTP server on the port given by PHOTOSPHERE_TEST_PORT.
    //
    start(): void {
        const portStr = process.env.PHOTOSPHERE_TEST_PORT;
        if (!portStr) {
            throw new Error('PHOTOSPHERE_TEST_PORT environment variable is not set');
        }
        const port = parseInt(portStr, 10);
        this.server.listen(port, '127.0.0.1', () => {
            log.info(`Test control server listening on port ${port}`);
        });
    }

    //
    // Signals that the main window has finished loading and is ready for test commands.
    //
    notifyReady(): void {
        this.isReady = true;
    }

    //
    // Shuts down the HTTP server.
    //
    close(): void {
        this.server.close();
    }
}
