import { Readable } from "stream";
import type { ITaskContext } from "task-queue";

// ── module mocks ─────────────────────────────────────────────────────────────

jest.mock("utils", () => ({
    log: { info: jest.fn(), error: jest.fn(), exception: jest.fn(), verbose: jest.fn() },
}));

jest.mock("../../lib/asset-server-core", () => ({
    createAssetServerCore: jest.fn(),
}));

import { createAssetServerCore } from "../../lib/asset-server-core";
import { assetServerHandler, type IAssetServerReadyMessage } from "../../lib/asset-server.worker";

const mockCreateAssetServerCore = createAssetServerCore as jest.MockedFunction<typeof createAssetServerCore>;

//
// The bytes the mocked core serves for every asset request.
//
const ASSET_BYTES = Buffer.from("hello-asset-bytes");

//
// Captures messages sent by the handler and exposes a controllable cancellation flag.
//
interface ITestContext {
    //
    // The task context passed to the handler.
    //
    context: ITaskContext;

    //
    // Messages captured from context.sendMessage.
    //
    messages: any[];

    //
    // Flips the handler's isCancelled() to true so it shuts down.
    //
    cancel(): void;
}

//
// Builds a test task context that records messages and supports cancellation.
//
function makeTestContext(): ITestContext {
    const messages: any[] = [];
    let cancelled = false;
    const context: ITaskContext = {
        uuidGenerator: { generate: jest.fn().mockReturnValue("uuid-1") },
        timestampProvider: { now: jest.fn().mockReturnValue(0), dateNow: jest.fn().mockReturnValue(new Date(0)) },
        sessionId: "test-session",
        taskId: "asset-server-task",
        sendMessage: (message: any) => { messages.push(message); },
        isCancelled: () => cancelled,
    };
    return { context, messages, cancel: () => { cancelled = true; } };
}

//
// Waits until the asset-server-ready message arrives and returns the bound port.
//
async function waitForReadyPort(messages: any[]): Promise<number> {
    for (let attempt = 0; attempt < 100; attempt++) {
        const ready = messages.find(message => message.type === "asset-server-ready") as IAssetServerReadyMessage | undefined;
        if (ready) {
            return ready.port;
        }
        await new Promise(resolve => setTimeout(resolve, 10));
    }
    throw new Error("asset-server-ready was not received in time");
}

describe("assetServerHandler", () => {
    beforeEach(() => {
        jest.clearAllMocks();
        mockCreateAssetServerCore.mockReturnValue({
            serveAsset: jest.fn().mockImplementation(async () => Readable.from([ASSET_BYTES])),
            writeAsset: jest.fn().mockResolvedValue(undefined),
            applyDatabaseOps: jest.fn().mockResolvedValue(undefined),
        });
    });

    test("binds a port, reports asset-server-ready, serves GET /asset, and stops on cancel", async () => {
        const test = makeTestContext();
        const handlerPromise = assetServerHandler({ port: 0 }, test.context);

        const port = await waitForReadyPort(test.messages);
        expect(port).toBeGreaterThan(0);

        const response = await fetch(`http://127.0.0.1:${port}/asset?id=asset-1&type=thumb&db=${encodeURIComponent("/db/path")}`);
        expect(response.status).toBe(200);
        const body = Buffer.from(await response.arrayBuffer());
        expect(body.equals(ASSET_BYTES)).toBe(true);

        test.cancel();
        const result = await handlerPromise;
        expect(result.port).toBe(port);
    });

    test("returns 400 when the id parameter is missing", async () => {
        const test = makeTestContext();
        const handlerPromise = assetServerHandler({ port: 0 }, test.context);

        const port = await waitForReadyPort(test.messages);
        const response = await fetch(`http://127.0.0.1:${port}/asset?type=thumb&db=${encodeURIComponent("/db/path")}`);
        expect(response.status).toBe(400);

        test.cancel();
        await handlerPromise;
    });

    test("binds the loopback interface and reports it in asset-server-ready", async () => {
        const test = makeTestContext();
        const handlerPromise = assetServerHandler({ port: 0 }, test.context);

        await waitForReadyPort(test.messages);
        const ready = test.messages.find(message => message.type === "asset-server-ready") as IAssetServerReadyMessage;
        expect(ready.host).toBe("127.0.0.1");

        test.cancel();
        await handlerPromise;
    });

    test("stops serving after the task is cancelled", async () => {
        const test = makeTestContext();
        const handlerPromise = assetServerHandler({ port: 0 }, test.context);

        const port = await waitForReadyPort(test.messages);
        test.cancel();
        await handlerPromise;

        // The server is closed, so a fetch to the (now released) port should fail to connect.
        await expect(fetch(`http://127.0.0.1:${port}/asset?id=asset-1&type=thumb&db=/db`)).rejects.toBeDefined();
    });
});
