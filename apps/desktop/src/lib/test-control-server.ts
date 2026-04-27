import express from 'express';
import type { Express } from 'express';
import http from 'http';
import { app, BrowserWindow, ipcMain } from 'electron';
import { log } from 'utils';

//
// Callbacks for test control server operations that require main-process logic.
//
export interface ITestControlServerCallbacks {
    // Creates a database at the given path and notifies the renderer.
    createDatabaseAtPath(databasePath: string): Promise<void>;
    // Notifies the renderer that a database was opened at the given path.
    openDatabase(databasePath: string): void;
    // Queues an import task for the given asset paths.
    importAssets(paths: string[]): void;
}

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
    // Callbacks to main-process operations.
    //
    private callbacks: ITestControlServerCallbacks;

    //
    // The underlying HTTP server instance.
    //
    private server: http.Server;

    constructor(mainWindow: BrowserWindow, callbacks: ITestControlServerCallbacks) {
        this.mainWindow = mainWindow;
        this.callbacks = callbacks;

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
            this.mainWindow.webContents.send('test-click', { dataId: req.body.dataId });
            res.json({ ok: true });
        });

        expressApp.post('/type', (req, res) => {
            this.mainWindow.webContents.send('test-type', { dataId: req.body.dataId, text: req.body.text });
            res.json({ ok: true });
        });

        expressApp.post('/create-database', async (req, res) => {
            await this.callbacks.createDatabaseAtPath(req.body.path);
            res.json({ ok: true });
        });

        expressApp.post('/open-database', (req, res) => {
            this.callbacks.openDatabase(req.body.path);
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
            this.callbacks.importAssets(req.body.paths);
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
