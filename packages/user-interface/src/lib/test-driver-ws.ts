//
// Mobile WebSocket test driver client.
//
// In test mode the mobile WebView opens an outbound WebSocket to the host control bridge
// (the app has no in-process HTTP server). Commands arrive as JSON messages, are dispatched
// through the shared DOM test driver, and replies are sent back over the same socket. Console
// output is forwarded as log messages so the host can write it to app.log.
//

import { installTestDriver } from "./test-driver";
import type { ITestTransport, ITestCommandPayload } from "./test-driver";

//
// A command message sent from the host bridge to the app.
//
export interface ITestWebSocketCommand {
    // Correlation id echoed back in the reply.
    id: number;

    // The command name (click, type, navigate, ...).
    command: string;

    // The command payload.
    payload: ITestCommandPayload;
}

//
// A message sent from the app back to the host bridge.
//
export interface ITestWebSocketMessage {
    // Message kind: "ready" once loaded, "reply" for a command result, "log" for console output.
    type: "ready" | "reply" | "log";

    // Correlation id (reply messages only).
    id?: number;

    // Whether the command succeeded (reply messages only).
    ok?: boolean;

    // The command result value (successful get-value replies).
    value?: string;

    // The error message (failed replies).
    error?: string;

    // Log level (log messages only).
    level?: string;

    // Log text (log messages only).
    message?: string;
}

//
// Shape of the injected test configuration read from globalThis. The native layer sets this
// so the WebView knows where to reach the host control bridge.
//
export interface ITestGlobalConfig {
    // Host the control bridge listens on (localhost on iOS simulator and adb-reversed Android).
    host: string;

    // Port the control bridge listens on.
    port: number;
}

//
// globalThis augmented with the injected test configuration.
//
interface ITestGlobal {
    // The injected test configuration, present only in test mode.
    __PHOTOSPHERE_TEST__?: ITestGlobalConfig;
}

//
// Whether the app has signaled that its test-command window listeners are mounted. "ready" is
// withheld from the host bridge until this is true so a command dispatched the instant the host
// sees /ready always finds its listener registered (the driver dispatches one-shot CustomEvents,
// which are silently dropped when no listener exists yet).
//
let testAppMounted = false;

//
// A deferred "send ready", set when the socket opens before the app has mounted. Invoked by
// signalTestAppReady once the app reports mounted.
//
let deferredSendReady: (() => void) | null = null;

//
// Called by the app (the mobile platform provider) once it has registered its test-command window
// listeners. Releases the withheld "ready" to the host bridge if the socket is already open.
//
export function signalTestAppReady(): void {
    testAppMounted = true;
    if (deferredSendReady) {
        const send = deferredSendReady;
        deferredSendReady = null;
        send();
    }
}

//
// The largest number of log messages held while the socket is still connecting. The buffer only has to
// cover app startup (the window between the console being patched and the socket opening), so this is
// far more than needed; it exists so a runaway logger cannot grow the buffer without bound. When it is
// full the newest messages are dropped, keeping the earliest startup diagnostics this buffer exists for.
//
const MAX_BUFFERED_LOGS = 500;

//
// Log messages produced before the socket reached OPEN, held in order and flushed on open. Without this
// every log emitted during early startup was silently discarded: the socket is still CONNECTING then, so
// the send was skipped and the line never reached app.log. That made startup diagnostics (notably the
// mobile keychain-secrets load) structurally invisible to the smoke tests.
//
let bufferedLogs: ITestWebSocketMessage[] = [];

//
// The socket log messages are sent over once it is open, or null before connectTestDriverWebSocket runs.
//
let activeSocket: WebSocket | null = null;

//
// Whether the console has already been patched, so patching again is a no-op rather than wrapping the
// console a second time (which would duplicate every line).
//
let consolePatched = false;

//
// The console.log replaced by patchConsole, kept so restoreConsole can put it back.
//
let originalConsoleLog: ((...args: unknown[]) => void) | null = null;

//
// The console.warn replaced by patchConsole, kept so restoreConsole can put it back.
//
let originalConsoleWarn: ((...args: unknown[]) => void) | null = null;

//
// The console.error replaced by patchConsole, kept so restoreConsole can put it back.
//
let originalConsoleError: ((...args: unknown[]) => void) | null = null;

//
// Sends a log message to the host bridge, or buffers it when the socket is not open yet so it is
// delivered, in order, once the connection completes.
//
function enqueueLog(message: ITestWebSocketMessage): void {
    if (activeSocket !== null && activeSocket.readyState === WebSocket.OPEN) {
        activeSocket.send(JSON.stringify(message));
        return;
    }

    if (bufferedLogs.length >= MAX_BUFFERED_LOGS) {
        // Full: keep the oldest, which are the startup diagnostics this buffer exists for.
        return;
    }
    bufferedLogs.push(message);
}

//
// Sends every buffered log message in order and empties the buffer. Called when the socket opens, before
// "ready", so the startup output is already in app.log by the time the host considers the app ready.
//
function flushBufferedLogs(): void {
    const pending = bufferedLogs;
    bufferedLogs = [];

    for (const message of pending) {
        if (activeSocket !== null && activeSocket.readyState === WebSocket.OPEN) {
            activeSocket.send(JSON.stringify(message));
        }
    }
}

//
// Test-only: resets the ready-gating, console-patch and log-buffer state so each unit test starts from a
// clean slate.
//
export function resetTestReadyGateForTests(): void {
    testAppMounted = false;
    deferredSendReady = null;
    activeSocket = null;
    bufferedLogs = [];
    restoreConsole();
}

//
// Opens a WebSocket to the host control bridge at the given URL, wires it to the shared DOM
// test driver, forwards console output as log messages, and sends "ready" once connected and the
// app has mounted its test-command listeners.
//
export function connectTestDriverWebSocket(url: string): void {
    const socket = new WebSocket(url);
    activeSocket = socket;

    //
    // The command handler registered by the shared driver via transport.onCommand.
    //
    let commandHandler: ((command: string, payload: ITestCommandPayload) => Promise<string | undefined>) | undefined;

    //
    // Sends a message to the host bridge if the socket is open.
    //
    function sendMessage(message: ITestWebSocketMessage): void {
        if (socket.readyState === WebSocket.OPEN) {
            socket.send(JSON.stringify(message));
        }
    }

    const transport: ITestTransport = {
        onCommand(handler: (command: string, payload: ITestCommandPayload) => Promise<string | undefined>): void {
            commandHandler = handler;
        },
        sendLog(level: string, message: string): void {
            enqueueLog({ type: "log", level, message });
        },
    };

    installTestDriver(transport);

    patchConsole();

    socket.addEventListener("open", () => {
        // Deliver anything logged while the socket was still connecting, in order and before "ready",
        // so early-startup output is in app.log rather than silently dropped.
        flushBufferedLogs();

        //
        // Withhold "ready" until the app has mounted its test-command window listeners. If it has
        // already mounted, send immediately; otherwise defer so a command issued the instant the
        // host sees /ready is never dropped for lack of a listener.
        //
        const sendReady = (): void => {
            sendMessage({ type: "ready" });
        };
        if (testAppMounted) {
            sendReady();
        }
        else {
            deferredSendReady = sendReady;
        }
    });

    // Surface connection failures: without these the socket fails silently, which is hard to
    // diagnose on a device (the host bridge just never sees a connection). These log via the
    // patched console so they appear in the native log (logcat / simulator console).
    socket.addEventListener("error", () => {
        console.error(`test-driver: WebSocket error connecting to ${url}`);
    });
    socket.addEventListener("close", (event: CloseEvent) => {
        console.warn(`test-driver: WebSocket closed (code ${event.code}) for ${url}`);
    });

    socket.addEventListener("message", async (event: MessageEvent) => {
        const raw = typeof event.data === "string" ? event.data : "";
        const data = JSON.parse(raw) as ITestWebSocketCommand;
        try {
            const value = commandHandler ? await commandHandler(data.command, data.payload) : undefined;
            sendMessage({ type: "reply", id: data.id, ok: true, value });
        }
        catch (error) {
            sendMessage({ type: "reply", id: data.id, ok: false, error: (error as Error).message });
        }
    });
}

//
// Patches console.log/warn/error to forward output to the host bridge, mirroring the desktop renderer's
// test-mode console patch so raw console output appears in app.log. Output produced before the socket
// opens is buffered by enqueueLog rather than dropped. Patching is idempotent, so calling it from both
// startTestDriverFromGlobal (early, to capture startup output) and connectTestDriverWebSocket wraps the
// console only once.
//
function patchConsole(): void {
    if (consolePatched) {
        return;
    }
    consolePatched = true;

    originalConsoleLog = console.log.bind(console);
    originalConsoleWarn = console.warn.bind(console);
    originalConsoleError = console.error.bind(console);
    console.log = (...args: unknown[]) => {
        originalConsoleLog!(...args);
        enqueueLog({ type: "log", level: "info", message: args.map(String).join(" ") });
    };
    console.warn = (...args: unknown[]) => {
        originalConsoleWarn!(...args);
        enqueueLog({ type: "log", level: "warn", message: args.map(String).join(" ") });
    };
    console.error = (...args: unknown[]) => {
        originalConsoleError!(...args);
        enqueueLog({ type: "log", level: "error", message: args.map(String).join(" ") });
    };
}

//
// Puts the original console methods back and discards any buffered output. Used when the app turns out
// not to be running in test mode, so a normal (non-test) run is not left with a patched console and a
// buffer that can never be flushed.
//
function restoreConsole(): void {
    if (!consolePatched) {
        return;
    }
    consolePatched = false;

    if (originalConsoleLog !== null) {
        console.log = originalConsoleLog;
    }
    if (originalConsoleWarn !== null) {
        console.warn = originalConsoleWarn;
    }
    if (originalConsoleError !== null) {
        console.error = originalConsoleError;
    }
    bufferedLogs = [];
}

//
// Starts the test driver if the native layer injected a test configuration. The global may be
// injected slightly after the WebView's scripts begin executing (Android injects it via the
// bridge once the page is up), so this polls briefly before giving up. A no-op outside test
// mode, so it is safe to call unconditionally on app start.
//
export function startTestDriverFromGlobal(): void {
    const maxAttempts = 50;
    let attempts = 0;

    // Patch the console before polling, not just once connected. The config arrives asynchronously, so
    // anything the app logs while this polls (app startup, including the keychain-secrets load) would
    // otherwise never be captured at all. enqueueLog buffers it until the socket opens. If no config
    // ever appears the app is not under test, and the poll restores the console below.
    patchConsole();

    function poll(): void {
        const config = (globalThis as ITestGlobal).__PHOTOSPHERE_TEST__;
        if (config && config.host && config.port) {
            console.log(`test-driver: connecting to host control bridge at ws://${config.host}:${config.port}`);
            connectTestDriverWebSocket(`ws://${config.host}:${config.port}`);
            return;
        }
        attempts += 1;
        if (attempts < maxAttempts) {
            setTimeout(poll, 100);
            return;
        }

        // Not running under test: undo the speculative console patch so a normal run is not left
        // forwarding into a buffer that will never be flushed.
        restoreConsole();
    }

    poll();
}
