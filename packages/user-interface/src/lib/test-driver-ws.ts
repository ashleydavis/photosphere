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
// Opens a WebSocket to the host control bridge at the given URL, wires it to the shared DOM
// test driver, forwards console output as log messages, and sends "ready" once connected.
//
export function connectTestDriverWebSocket(url: string): void {
    const socket = new WebSocket(url);

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
            sendMessage({ type: "log", level, message });
        },
    };

    installTestDriver(transport);

    patchConsole(transport);

    socket.addEventListener("open", () => {
        sendMessage({ type: "ready" });
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
// Patches console.log/warn/error to forward output over the transport, mirroring the desktop
// renderer's test-mode console patch so raw console output appears in app.log.
//
function patchConsole(transport: ITestTransport): void {
    const originalLog = console.log.bind(console);
    const originalWarn = console.warn.bind(console);
    const originalError = console.error.bind(console);
    console.log = (...args: unknown[]) => {
        originalLog(...args);
        transport.sendLog("info", args.map(String).join(" "));
    };
    console.warn = (...args: unknown[]) => {
        originalWarn(...args);
        transport.sendLog("warn", args.map(String).join(" "));
    };
    console.error = (...args: unknown[]) => {
        originalError(...args);
        transport.sendLog("error", args.map(String).join(" "));
    };
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
        }
    }

    poll();
}
