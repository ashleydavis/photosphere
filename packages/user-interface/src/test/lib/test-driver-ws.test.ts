/**
 * @jest-environment jsdom
 */

import { connectTestDriverWebSocket, signalTestAppReady, resetTestReadyGateForTests } from "../../lib/test-driver-ws";

//
// A minimal fake WebSocket that records sent messages and lets tests fire events.
//
class FakeWebSocket {
    //
    // The CONNECTING ready-state constant, mirrored from the real WebSocket.
    //
    static CONNECTING = 0;

    //
    // The OPEN ready-state constant, mirrored from the real WebSocket.
    //
    static OPEN = 1;

    //
    // All instances created, so tests can grab the latest.
    //
    static instances: FakeWebSocket[] = [];

    //
    // The URL passed to the constructor.
    //
    url: string;

    //
    // Current ready state. Starts CONNECTING and becomes OPEN when an "open" event is emitted, matching
    // the real socket so tests can exercise the pre-open log buffering.
    //
    readyState = FakeWebSocket.CONNECTING;

    //
    // JSON strings passed to send().
    //
    sent: string[] = [];

    //
    // Registered event listeners keyed by event type.
    //
    private listeners: Record<string, ((event: unknown) => void)[]> = {};

    constructor(url: string) {
        this.url = url;
        FakeWebSocket.instances.push(this);
    }

    addEventListener(type: string, callback: (event: unknown) => void): void {
        (this.listeners[type] = this.listeners[type] || []).push(callback);
    }

    send(data: string): void {
        this.sent.push(data);
    }

    //
    // Fires an event of the given type to all registered listeners.
    //
    emit(type: string, event: unknown): void {
        if (type === "open") {
            this.readyState = FakeWebSocket.OPEN;
        }
        for (const callback of this.listeners[type] || []) {
            callback(event);
        }
    }
}

//
// Flushes pending microtasks/timers so async message handlers complete.
//
function flush(): Promise<void> {
    return new Promise<void>((resolve) => { setTimeout(resolve, 0); });
}

describe("connectTestDriverWebSocket", () => {

    const originalWebSocket = (globalThis as any).WebSocket;
    const originalConsoleLog = console.log;
    const originalConsoleWarn = console.warn;
    const originalConsoleError = console.error;

    beforeEach(() => {
        FakeWebSocket.instances = [];
        (globalThis as any).WebSocket = FakeWebSocket;
        resetTestReadyGateForTests();
    });

    afterEach(() => {
        (globalThis as any).WebSocket = originalWebSocket;
        console.log = originalConsoleLog;
        console.warn = originalConsoleWarn;
        console.error = originalConsoleError;
    });

    test("withholds ready until the app signals mounted, then sends it", () => {
        connectTestDriverWebSocket("ws://localhost:1234");
        const socket = FakeWebSocket.instances[0];
        socket.emit("open", {});

        // Ready must not be sent yet: the app's command listeners are not mounted, so a command
        // arriving now would be dropped.
        expect(socket.sent.map((raw) => JSON.parse(raw))).not.toContainEqual({ type: "ready" });

        signalTestAppReady();
        expect(socket.sent.map((raw) => JSON.parse(raw))).toContainEqual({ type: "ready" });
    });

    test("sends ready immediately when the app mounted before the socket opened", () => {
        signalTestAppReady();
        connectTestDriverWebSocket("ws://localhost:1234");
        const socket = FakeWebSocket.instances[0];
        socket.emit("open", {});
        expect(socket.sent.map((raw) => JSON.parse(raw))).toContainEqual({ type: "ready" });
    });

    test("dispatches a command to the driver and replies with the matching id", async () => {
        document.body.innerHTML = `<button data-id="go">go</button>`;
        const button = document.querySelector(`[data-id="go"]`) as HTMLButtonElement;
        let clicked = 0;
        button.addEventListener("click", () => { clicked += 1; });

        connectTestDriverWebSocket("ws://localhost:1234");
        const socket = FakeWebSocket.instances[0];
        socket.emit("open", {});
        socket.emit("message", { data: JSON.stringify({ id: 42, command: "click", payload: { dataId: "go" } }) });
        await flush();

        expect(clicked).toBe(1);
        const reply = socket.sent.map((raw) => JSON.parse(raw)).find((message) => message.type === "reply");
        expect(reply).toEqual({ type: "reply", id: 42, ok: true, value: undefined });
    });

    test("replies ok:false when a command is not implemented", async () => {
        connectTestDriverWebSocket("ws://localhost:1234");
        const socket = FakeWebSocket.instances[0];
        socket.emit("open", {});
        socket.emit("message", { data: JSON.stringify({ id: 7, command: "create-database", payload: {} }) });
        await flush();

        const reply = socket.sent.map((raw) => JSON.parse(raw)).find((message) => message.type === "reply");
        expect(reply.id).toBe(7);
        expect(reply.ok).toBe(false);
        expect(reply.error).toContain("not implemented");
    });

    test("forwards console output as log messages", () => {
        connectTestDriverWebSocket("ws://localhost:1234");
        const socket = FakeWebSocket.instances[0];
        socket.emit("open", {});
        console.log("hello from app");
        const logMessage = socket.sent.map((raw) => JSON.parse(raw)).find((message) => message.type === "log");
        expect(logMessage).toEqual({ type: "log", level: "info", message: "hello from app" });
    });

    test("buffers logs emitted before the socket opens and flushes them in order on open", () => {
        connectTestDriverWebSocket("ws://localhost:1234");
        const socket = FakeWebSocket.instances[0];

        // The socket is still CONNECTING here. Before buffering these were silently discarded, which is
        // what made app-startup diagnostics invisible in app.log.
        console.log("startup one");
        console.error("startup two");
        expect(socket.sent).toHaveLength(0);

        socket.emit("open", {});

        const logMessages = socket.sent.map((raw) => JSON.parse(raw)).filter((message) => message.type === "log");
        expect(logMessages).toEqual([
            { type: "log", level: "info", message: "startup one" },
            { type: "log", level: "error", message: "startup two" },
        ]);
    });

    test("flushes buffered logs before ready, so startup output is in the log by the time the host sees ready", () => {
        signalTestAppReady();
        connectTestDriverWebSocket("ws://localhost:1234");
        const socket = FakeWebSocket.instances[0];

        console.log("before ready");
        socket.emit("open", {});

        const kinds = socket.sent.map((raw) => JSON.parse(raw).type);
        expect(kinds.indexOf("log")).toBeLessThan(kinds.indexOf("ready"));
    });

    test("caps the pre-open buffer, keeping the OLDEST logs so startup diagnostics survive", () => {
        // Silence the real console first so the patch forwards to a no-op and the run stays quiet.
        console.log = () => {};

        connectTestDriverWebSocket("ws://localhost:1234");
        const socket = FakeWebSocket.instances[0];

        for (let index = 0; index < 600; index += 1) {
            console.log(`line ${index}`);
        }
        socket.emit("open", {});

        const logMessages = socket.sent.map((raw) => JSON.parse(raw)).filter((message) => message.type === "log");
        expect(logMessages).toHaveLength(500);
        // The earliest lines are the ones the buffer exists to preserve, so they must be the survivors.
        expect(logMessages[0].message).toBe("line 0");
        expect(logMessages[499].message).toBe("line 499");
    });
});
