import fs from "fs";
import os from "os";
import path from "path";
import { WebSocket as WsClient } from "ws";
import { ControlBridge } from "../../lib/control-bridge";

//
// A command received by the fake app over the WebSocket.
//
interface IReceivedCommand {
    // Correlation id.
    id: number;

    // Command name.
    command: string;

    // Command payload.
    payload: Record<string, unknown>;
}

//
// A reply the fake app sends for the next command, configurable per test.
//
interface IFakeReply {
    // Whether the command succeeded.
    ok: boolean;

    // Result value for successful replies.
    value?: string;

    // Error message for failed replies.
    error?: string;
}

//
// Waits the given number of milliseconds.
//
function delay(ms: number): Promise<void> {
    return new Promise<void>((resolve) => { setTimeout(resolve, ms); });
}

describe("control bridge", () => {

    let bridge: ControlBridge;
    let client: WsClient;
    let logDir: string;
    let baseUrl: string;
    const received: IReceivedCommand[] = [];
    let nextReply: IFakeReply = { ok: true };

    beforeAll(async () => {
        logDir = fs.mkdtempSync(path.join(os.tmpdir(), "control-bridge-"));
        bridge = new ControlBridge({ port: 0, logDir });
        await bridge.start();
        baseUrl = `http://localhost:${bridge.port}`;

        client = new WsClient(`ws://localhost:${bridge.port}`);
        await new Promise<void>((resolve, reject) => {
            client.on("open", () => resolve());
            client.on("error", reject);
        });

        // The fake app: record each command and reply per the configured nextReply.
        client.on("message", (raw: Buffer) => {
            const command = JSON.parse(raw.toString()) as IReceivedCommand;
            received.push(command);
            client.send(JSON.stringify({ type: "reply", id: command.id, ...nextReply }));
        });

        // Give the bridge's connection handler a moment to register the socket.
        await delay(50);
    });

    afterAll(async () => {
        client.close();
        await bridge.stop();
        fs.rmSync(logDir, { recursive: true, force: true });
    });

    beforeEach(() => {
        received.length = 0;
        nextReply = { ok: true };
    });

    test("forwards a click command with the correct payload", async () => {
        const response = await fetch(`${baseUrl}/click`, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ dataId: "my-button", nth: 2 }),
        });
        const body = await response.json();
        expect(response.status).toBe(200);
        expect(body.ok).toBe(true);
        expect(received).toHaveLength(1);
        expect(received[0].command).toBe("click");
        expect(received[0].payload).toEqual({ dataId: "my-button", nth: 2 });
    });

    test("forwards a navigate command", async () => {
        await fetch(`${baseUrl}/navigate`, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ page: "/cloud" }),
        });
        expect(received[0].command).toBe("navigate");
        expect(received[0].payload).toEqual({ page: "/cloud" });
    });

    test("forwards a cycle-advance command", async () => {
        await fetch(`${baseUrl}/cycle-advance`, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({}),
        });
        expect(received[0].command).toBe("cycle-advance");
        expect(received[0].payload).toEqual({});
    });

    test("returns the value from a get-value reply", async () => {
        nextReply = { ok: true, value: "hello world" };
        const response = await fetch(`${baseUrl}/get-value?dataId=field`);
        const body = await response.json();
        expect(body.ok).toBe(true);
        expect(body.value).toBe("hello world");
        expect(received[0].command).toBe("get-value");
        expect(received[0].payload).toEqual({ dataId: "field" });
    });

    test("returns ok:false when the app replies with an error", async () => {
        nextReply = { ok: false, error: "Test command not implemented on this platform: create-database" };
        const response = await fetch(`${baseUrl}/create-database`, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ path: "/tmp/db" }),
        });
        const body = await response.json();
        expect(response.status).toBe(500);
        expect(body.ok).toBe(false);
        expect(body.error).toContain("not implemented");
    });

    test("appends forwarded log messages to app.log in [LEVEL] format", async () => {
        client.send(JSON.stringify({ type: "log", level: "error", message: "something broke" }));
        client.send(JSON.stringify({ type: "log", level: "info", message: "all good" }));
        await delay(50);
        const logContents = fs.readFileSync(path.join(logDir, "app.log"), "utf8");
        expect(logContents).toContain("[ERROR] something broke");
        expect(logContents).toContain("[INFO] all good");
    });

    test("/ready returns 503 until the app sends ready, then 200", async () => {
        const before = await fetch(`${baseUrl}/ready`);
        expect(before.status).toBe(503);

        client.send(JSON.stringify({ type: "ready" }));
        await delay(50);

        const after = await fetch(`${baseUrl}/ready`);
        const body = await after.json();
        expect(after.status).toBe(200);
        expect(body.ok).toBe(true);
    });
});

describe("control bridge OS-assigned port", () => {

    test("binds a distinct OS-assigned port for each bridge", async () => {
        //
        // The bridge always binds an OS-assigned free port (port 0) so two concurrent runs never
        // pick the same number. Start two bridges and confirm each gets a real, distinct port.
        //
        const logDirA = fs.mkdtempSync(path.join(os.tmpdir(), "control-bridge-a-"));
        const logDirB = fs.mkdtempSync(path.join(os.tmpdir(), "control-bridge-b-"));
        const bridgeA = new ControlBridge({ port: 0, logDir: logDirA });
        const bridgeB = new ControlBridge({ port: 0, logDir: logDirB });
        await bridgeA.start();
        await bridgeB.start();

        expect(bridgeA.port).toBeGreaterThan(0);
        expect(bridgeB.port).toBeGreaterThan(0);
        expect(bridgeA.port).not.toBe(bridgeB.port);

        await bridgeA.stop();
        await bridgeB.stop();
        fs.rmSync(logDirA, { recursive: true, force: true });
        fs.rmSync(logDirB, { recursive: true, force: true });
    });
});
