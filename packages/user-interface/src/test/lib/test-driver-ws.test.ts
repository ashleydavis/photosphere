/**
 * @jest-environment jsdom
 */

import { connectTestDriverWebSocket, signalTestAppReady, resetTestReadyGateForTests } from "../../lib/test-driver-ws";

//
// A minimal fake WebSocket that records sent messages and lets tests fire events.
//
class FakeWebSocket {
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
    // Current ready state (always OPEN for the fake).
    //
    readyState = FakeWebSocket.OPEN;

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

    test("routes screenshot through platformHandlers and returns the value", async () => {
        connectTestDriverWebSocket("ws://localhost:1234", {
            screenshot: async () => "YmFzZTY0",
        });
        const socket = FakeWebSocket.instances[0];
        socket.emit("open", {});
        socket.emit("message", { data: JSON.stringify({ id: 9, command: "screenshot", payload: {} }) });
        await flush();

        const reply = socket.sent.map((raw) => JSON.parse(raw)).find((message) => message.type === "reply");
        expect(reply).toEqual({ type: "reply", id: 9, ok: true, value: "YmFzZTY0" });
    });

    test("forwards console output as log messages", () => {
        connectTestDriverWebSocket("ws://localhost:1234");
        const socket = FakeWebSocket.instances[0];
        socket.emit("open", {});
        console.log("hello from app");
        const logMessage = socket.sent.map((raw) => JSON.parse(raw)).find((message) => message.type === "log");
        expect(logMessage).toEqual({ type: "log", level: "info", message: "hello from app" });
    });
});
