//
// Host control bridge for host-driven UI smoke tests.
//
// A mobile app has no in-process HTTP server (no Node), so the Electron-style in-app test
// control server cannot run inside it. Instead this host-side bridge presents the same HTTP
// command surface to the test scripts (/ready, /navigate, /click, ...) and relays each
// command to the app over a WebSocket the app opens on launch in test mode. The DOM-driving
// behaviour is identical to desktop because both shells run the same shared test driver.
// Nothing here is mobile-specific, so an Electron shell could adopt the same bridge later.
//
// The bridge is intentionally transport-only: app-level commands (click/type/navigate/...)
// are forwarded to the app and answered by the shared driver; screenshot and quit are handled
// host-side because they are device operations.
//

import express from "express";
import type { Express, Request, Response } from "express";
import http from "http";
import fs from "fs";
import path from "path";
import { spawn } from "child_process";
import { WebSocketServer, WebSocket } from "ws";

//
// Options for constructing a control bridge.
//
export interface IControlBridgeOptions {
    // Port to listen on for both HTTP commands and the app's WebSocket connection. Use 0 to
    // pick a free port (read back via the `port` getter), which the tests rely on.
    port: number;

    // Directory the bridge appends app-forwarded log lines to (as app.log), in the same
    // `[LEVEL] message` format the desktop app uses so check_no_errors/wait_for_log work.
    logDir: string;

    // Active platform ("android" or "ios"), used to pick host-side screenshot/quit commands.
    platform?: string;

    // Android application id, used for the host-side quit command.
    appId?: string;

    // iOS bundle id, used for the host-side quit command.
    bundleId?: string;

    // iOS simulator UDID to target for screenshot/quit (defaults to "booted").
    iosUdid?: string;
}

//
// A command message sent from the bridge to the app.
//
interface IBridgeCommand {
    // Correlation id echoed back in the reply.
    id: number;

    // The command name (click, type, navigate, ...).
    command: string;

    // The command payload.
    payload: IBridgePayload;
}

//
// Payload forwarded with a command. Fields are optional; each command uses the subset it needs.
//
interface IBridgePayload {
    // Target element data-id (click/long-press-click/type/drop/get-value).
    dataId?: string;

    // Index when several elements share a data-id.
    nth?: number;

    // Text to type.
    text?: string;

    // Paths to drop / import.
    paths?: string[];

    // Route to navigate to.
    page?: string;

    // Menu item id.
    itemId?: string;

    // Database path (create/open-database).
    path?: string;

    // Database entries to seed into the mobile config store (seed-databases).
    databases?: Array<{ name: string; description?: string; path: string }>;

    // Secret records to seed into the mobile config store (seed-secrets).
    secrets?: Array<{ entry: { name: string; type: string }; value: string }>;

    // Database entries to seed into the recent-databases list (seed-recent).
    recent?: Array<{ name: string; description?: string; path: string }>;

    // News items to seed into the mobile config store (seed-news).
    news?: Array<{ id: string; message: string; color?: string }>;
}

//
// A message sent from the app back to the bridge.
//
interface IAppMessage {
    // Message kind.
    type: "ready" | "reply" | "log";

    // Correlation id (reply messages).
    id?: number;

    // Whether the command succeeded (reply messages).
    ok?: boolean;

    // Result value (successful get-value replies).
    value?: string;

    // Error message (failed replies).
    error?: string;

    // Log level (log messages).
    level?: string;

    // Log text (log messages).
    message?: string;
}

//
// Tracks a single in-flight command awaiting the app's reply.
//
interface IPendingCommand {
    // Resolves the HTTP request with the app's reply value.
    resolve: (message: IAppMessage) => void;

    // Rejects the HTTP request (no app connected, timeout).
    reject: (error: Error) => void;

    // Timer that rejects the command if the app never replies.
    timer: NodeJS.Timeout;
}

//
// How long to wait for the app to reply to a forwarded command before failing.
//
const COMMAND_TIMEOUT_MS = 30000;

//
// The host control bridge. Start it with start(), stop it with stop(). It is constructed in
// tests against a fake WebSocket client and started by the smoke-test harness as a Bun
// process for real runs.
//
export class ControlBridge {
    //
    // Bridge options.
    //
    private options: IControlBridgeOptions;

    //
    // The Express application handling HTTP commands.
    //
    private expressApp: Express;

    //
    // The underlying HTTP server (shared by Express and the WebSocket server).
    //
    private httpServer: http.Server;

    //
    // The WebSocket server the app connects to.
    //
    private webSocketServer: WebSocketServer;

    //
    // The currently connected app socket, or null when no app is connected.
    //
    private appSocket: WebSocket | null = null;

    //
    // Whether the app has sent its "ready" message.
    //
    private isReady: boolean = false;

    //
    // Monotonic command id counter.
    //
    private nextCommandId: number = 0;

    //
    // In-flight commands awaiting replies, keyed by command id.
    //
    private pending: Map<number, IPendingCommand> = new Map();

    //
    // Absolute path to the app log file the bridge appends forwarded log lines to.
    //
    private logFilePath: string;

    constructor(options: IControlBridgeOptions) {
        this.options = options;
        this.logFilePath = path.join(options.logDir, "app.log");

        this.expressApp = express();
        this.expressApp.use(express.json());
        this.registerRoutes();

        this.httpServer = http.createServer(this.expressApp);
        this.webSocketServer = new WebSocketServer({ server: this.httpServer });
        this.webSocketServer.on("connection", (socket: WebSocket) => {
            this.onAppConnected(socket);
        });
    }

    //
    // Starts listening for HTTP commands and WebSocket connections. Resolves once listening.
    //
    start(): Promise<void> {
        return new Promise<void>((resolve, reject) => {
            //
            // The chosen port is free when the harness picks it, but on a busy machine another
            // process can transiently grab it during the ~1s window before this server binds,
            // producing EADDRINUSE. Without an error handler the server emits an unhandled error
            // and the process dies, so the bridge never comes up. Retry the bind on that transient
            // collision (the grabbing socket is short-lived) until the port frees, so a random port
            // race does not fail the whole test run.
            //
            const retryDelayMs = 100;
            const maxAttempts = 150;
            let attempts = 0;
            const attemptListen = (): void => {
                const onError = (error: NodeJS.ErrnoException): void => {
                    if (error.code === "EADDRINUSE" && attempts < maxAttempts) {
                        attempts += 1;
                        setTimeout(attemptListen, retryDelayMs);
                    }
                    else {
                        reject(error);
                    }
                };
                this.httpServer.once("error", onError);
                //
                // Bind to loopback only. This is a test-control server driven from the same machine (the
                // iOS simulator and Android emulator both reach the host loopback interface), so it must
                // never be exposed on the LAN.
                //
                this.httpServer.listen(this.options.port, "127.0.0.1", () => {
                    this.httpServer.removeListener("error", onError);
                    resolve();
                });
            };
            attemptListen();
        });
    }

    //
    // Stops the bridge, closing the WebSocket and HTTP servers.
    //
    stop(): Promise<void> {
        return new Promise<void>((resolve) => {
            for (const command of this.pending.values()) {
                clearTimeout(command.timer);
                command.reject(new Error("Bridge stopped"));
            }
            this.pending.clear();
            this.webSocketServer.close(() => {
                this.httpServer.close(() => {
                    resolve();
                });
            });
        });
    }

    //
    // The port the bridge is listening on (resolved port when 0 was requested).
    //
    get port(): number {
        const address = this.httpServer.address();
        if (address && typeof address !== "string") {
            return address.port;
        }
        return this.options.port;
    }

    //
    // Handles a newly connected app socket: records it and wires its message handler.
    //
    private onAppConnected(socket: WebSocket): void {
        this.appSocket = socket;
        this.appendLog("info", "App connected to control bridge");
        socket.on("message", (raw: Buffer) => {
            this.onAppMessage(raw.toString());
        });
        socket.on("close", () => {
            if (this.appSocket === socket) {
                this.appSocket = null;
            }
        });
    }

    //
    // Handles a message from the app: ready, command reply, or forwarded log line.
    //
    private onAppMessage(raw: string): void {
        const message = JSON.parse(raw) as IAppMessage;
        if (message.type === "ready") {
            this.isReady = true;
            return;
        }
        if (message.type === "log") {
            this.appendLog(message.level || "info", message.message || "");
            return;
        }
        if (message.type === "reply" && message.id !== undefined) {
            const command = this.pending.get(message.id);
            if (command) {
                clearTimeout(command.timer);
                this.pending.delete(message.id);
                command.resolve(message);
            }
        }
    }

    //
    // Forwards a command to the connected app and resolves with the app's reply.
    //
    private sendCommand(command: string, payload: IBridgePayload): Promise<IAppMessage> {
        return new Promise<IAppMessage>((resolve, reject) => {
            if (!this.appSocket || this.appSocket.readyState !== WebSocket.OPEN) {
                reject(new Error("No app connected to control bridge"));
                return;
            }
            const id = this.nextCommandId++;
            const timer = setTimeout(() => {
                this.pending.delete(id);
                reject(new Error(`Timed out waiting for app reply to command: ${command}`));
            }, COMMAND_TIMEOUT_MS);
            this.pending.set(id, { resolve, reject, timer });
            const outbound: IBridgeCommand = { id, command, payload };
            this.appSocket.send(JSON.stringify(outbound));
        });
    }

    //
    // Appends a log line to app.log in the `[LEVEL] message` format the harness expects.
    //
    private appendLog(level: string, message: string): void {
        fs.mkdirSync(this.options.logDir, { recursive: true });
        fs.appendFileSync(this.logFilePath, `[${level.toUpperCase()}] ${message}\n`);
    }

    //
    // Forwards a command to the app and writes the HTTP response from the reply. Used by the
    // command endpoints so they share one error/reply path.
    //
    private async forward(command: string, payload: IBridgePayload, res: Response): Promise<void> {
        try {
            const reply = await this.sendCommand(command, payload);
            if (reply.ok) {
                res.json({ ok: true, value: reply.value });
            }
            else {
                res.status(500).json({ ok: false, error: reply.error || "Command failed" });
            }
        }
        catch (error) {
            res.status(500).json({ ok: false, error: (error as Error).message });
        }
    }

    //
    // Registers all HTTP command routes, mirroring the desktop TestControlServer surface.
    //
    private registerRoutes(): void {
        this.expressApp.get("/ready", (_req: Request, res: Response) => {
            if (this.isReady) {
                res.json({ ok: true });
            }
            else {
                res.status(503).json({ ok: false, error: "Not ready yet" });
            }
        });

        this.expressApp.post("/navigate", (req: Request, res: Response) => {
            void this.forward("navigate", { page: req.body.page }, res);
        });

        this.expressApp.post("/menu", (req: Request, res: Response) => {
            void this.forward("menu", { itemId: req.body.itemId }, res);
        });

        this.expressApp.post("/click", (req: Request, res: Response) => {
            void this.forward("click", { dataId: req.body.dataId, nth: req.body.nth }, res);
        });

        this.expressApp.post("/long-press-click", (req: Request, res: Response) => {
            void this.forward("long-press-click", { dataId: req.body.dataId, nth: req.body.nth }, res);
        });

        this.expressApp.post("/type", (req: Request, res: Response) => {
            void this.forward("type", { dataId: req.body.dataId, text: req.body.text }, res);
        });

        this.expressApp.post("/drop", (req: Request, res: Response) => {
            void this.forward("drop", { dataId: req.body.dataId, paths: req.body.paths }, res);
        });

        this.expressApp.post("/pick-files", (req: Request, res: Response) => {
            void this.forward("pick-files", { paths: req.body.paths }, res);
        });

        this.expressApp.get("/get-value", (req: Request, res: Response) => {
            void this.forward("get-value", { dataId: req.query.dataId as string }, res);
        });

        this.expressApp.post("/lan-share-roundtrip", (_req: Request, res: Response) => {
            void this.forward("lan-share-roundtrip", {}, res);
        });

        this.expressApp.post("/create-database", (req: Request, res: Response) => {
            void this.forward("create-database", { path: req.body.path }, res);
        });

        this.expressApp.post("/open-database", (req: Request, res: Response) => {
            void this.forward("open-database", { path: req.body.path }, res);
        });

        this.expressApp.post("/import-assets", (req: Request, res: Response) => {
            void this.forward("import-assets", { paths: req.body.paths }, res);
        });

        this.expressApp.post("/data", (req: Request, res: Response) => {
            void this.forward("data", req.body, res);
        });

        this.expressApp.post("/seed-databases", (req: Request, res: Response) => {
            void this.forward("seed-databases", { databases: req.body.databases }, res);
        });

        this.expressApp.post("/seed-secrets", (req: Request, res: Response) => {
            void this.forward("seed-secrets", { secrets: req.body.secrets }, res);
        });

        this.expressApp.post("/seed-recent", (req: Request, res: Response) => {
            void this.forward("seed-recent", { recent: req.body.recent }, res);
        });

        this.expressApp.post("/seed-news", (req: Request, res: Response) => {
            void this.forward("seed-news", { news: req.body.news }, res);
        });

        this.expressApp.post("/reset-config", (req: Request, res: Response) => {
            void this.forward("reset-config", {}, res);
        });

        //
        // Advances the stories cycle to the next story. Mirrors the Electron test-control-server's
        // /cycle-advance route so the shared stories runner drives every platform identically.
        //
        this.expressApp.post("/cycle-advance", (_req: Request, res: Response) => {
            void this.forward("cycle-advance", {}, res);
        });

        this.expressApp.post("/screenshot", (req: Request, res: Response) => {
            void this.handleScreenshot(req.body.outputPath, res);
        });

        this.expressApp.post("/quit", (_req: Request, res: Response) => {
            void this.handleQuit(res);
        });
    }

    //
    // Captures a screenshot host-side using the platform's screen-capture tool.
    //
    private async handleScreenshot(outputPath: string, res: Response): Promise<void> {
        try {
            await fs.promises.mkdir(path.dirname(outputPath), { recursive: true });
            if (this.options.platform === "android") {
                const png = await runCommandCapture("adb", ["exec-out", "screencap", "-p"]);
                await fs.promises.writeFile(outputPath, png);
            }
            else if (this.options.platform === "ios") {
                await runCommand("xcrun", ["simctl", "io", this.options.iosUdid || "booted", "screenshot", outputPath]);
            }
            else {
                res.status(500).json({ ok: false, error: `Screenshot not supported for platform: ${this.options.platform}` });
                return;
            }
            res.json({ ok: true, outputPath });
        }
        catch (error) {
            res.status(500).json({ ok: false, error: (error as Error).message });
        }
    }

    //
    // Stops the app host-side using the platform's stop command.
    //
    private async handleQuit(res: Response): Promise<void> {
        try {
            if (this.options.platform === "android" && this.options.appId) {
                await runCommand("adb", ["shell", "am", "force-stop", this.options.appId]);
            }
            else if (this.options.platform === "ios" && this.options.bundleId) {
                await runCommand("xcrun", ["simctl", "terminate", this.options.iosUdid || "booted", this.options.bundleId]);
            }
            res.json({ ok: true });
        }
        catch (error) {
            res.status(500).json({ ok: false, error: (error as Error).message });
        }
    }
}

//
// Runs a command to completion, rejecting on a non-zero exit.
//
function runCommand(command: string, args: string[]): Promise<void> {
    return new Promise<void>((resolve, reject) => {
        const child = spawn(command, args);
        let stderr = "";
        child.stderr.on("data", (chunk: Buffer) => { stderr += chunk.toString(); });
        child.on("error", reject);
        child.on("close", (code: number) => {
            if (code === 0) {
                resolve();
            }
            else {
                reject(new Error(`${command} exited with code ${code}: ${stderr}`));
            }
        });
    });
}

//
// Runs a command and resolves with its captured stdout as a Buffer (used for binary output
// such as screencap PNG data).
//
function runCommandCapture(command: string, args: string[]): Promise<Buffer> {
    return new Promise<Buffer>((resolve, reject) => {
        const child = spawn(command, args);
        const chunks: Buffer[] = [];
        let stderr = "";
        child.stdout.on("data", (chunk: Buffer) => { chunks.push(chunk); });
        child.stderr.on("data", (chunk: Buffer) => { stderr += chunk.toString(); });
        child.on("error", reject);
        child.on("close", (code: number) => {
            if (code === 0) {
                resolve(Buffer.concat(chunks));
            }
            else {
                reject(new Error(`${command} exited with code ${code}: ${stderr}`));
            }
        });
    });
}

//
// Constructs and starts a control bridge from the PHOTOSPHERE_* environment variables, used by
// the smoke-test harness which runs this as a Bun process.
//
export async function runBridgeFromEnv(): Promise<ControlBridge> {
    const portStr = process.env.PHOTOSPHERE_TEST_PORT;
    if (!portStr) {
        throw new Error("PHOTOSPHERE_TEST_PORT environment variable is not set");
    }
    const logDir = process.env.PHOTOSPHERE_LOG_DIR;
    if (!logDir) {
        throw new Error("PHOTOSPHERE_LOG_DIR environment variable is not set");
    }
    const bridge = new ControlBridge({
        port: parseInt(portStr, 10),
        logDir,
        platform: process.env.PHOTOSPHERE_TEST_PLATFORM,
        appId: process.env.PHOTOSPHERE_TEST_APP_ID,
        bundleId: process.env.PHOTOSPHERE_TEST_BUNDLE_ID,
        iosUdid: process.env.PHOTOSPHERE_TEST_IOS_UDID,
    });
    await bridge.start();
    return bridge;
}
