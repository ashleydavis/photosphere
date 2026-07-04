import { Buffer } from "buffer";
import { registerHandler, ITaskContext, TaskQueue, TaskStatus } from "task-queue";
import { RandomUuidGenerator } from "utils";
import { runTask, installWorkerGlobal, deliverChildEvent } from "../lib/mobile-worker-runtime";
import { IHost } from "../lib/host-functions";

//
// A child task queued via host.queueTask, captured by the mock host for assertions.
//
interface IQueuedTask {
    // The child task id.
    taskId: string;

    // The child handler type.
    type: string;

    // The JSON-encoded child input data.
    dataJson: string;

    // The source tag grouping the child task.
    source: string;
}

//
// Builds a mock native host bridge for the tests, capturing calls to
// sendMessage / isCancelled so the tests can assert routing.
//
interface IMockHost extends IHost {
    // Records every (taskId, messageJson) passed to sendMessage.
    sentMessages: Array<{ taskId: string; messageJson: string }>;

    // Records every taskId passed to isCancelled.
    cancelledChecks: string[];

    // Records every child task queued via queueTask.
    queuedTasks: IQueuedTask[];
}

function createMockHost(sessionId: string): IMockHost {
    const sentMessages: Array<{ taskId: string; messageJson: string }> = [];
    const cancelledChecks: string[] = [];
    const queuedTasks: IQueuedTask[] = [];
    const mockHost: IMockHost = {
        platform: "android",
        sessionId,
        sentMessages,
        cancelledChecks,
        queuedTasks,
        sendMessage: (taskId: string, messageJson: string) => {
            sentMessages.push({ taskId, messageJson });
        },
        isCancelled: (taskId: string) => {
            cancelledChecks.push(taskId);
            return false;
        },
        queueTask: (taskId: string, type: string, dataJson: string, source: string) => {
            queuedTasks.push({ taskId, type, dataJson, source });
        },
        sha256: (path: string) => `sha256(${path})`,
        fsReadFile: () => null,
        fsAccess: () => false,
        fsStat: () => null,
        fsReaddir: () => null,
        fsWriteFile: () => { /* no-op */ },
        fsMkdir: () => { /* no-op */ },
        fsRename: () => { /* no-op */ },
        fsUnlink: () => { /* no-op */ },
        fsRm: () => { /* no-op */ },
        tcpListen: () => JSON.stringify({ listenerId: "L1", port: 0 }),
        tcpWrite: () => null,
        tcpClose: () => null,
        tcpStopListening: () => null,
        imageMagick: () => JSON.stringify({ exitCode: 0, output: "" }),
        ffmpeg: () => JSON.stringify({ exitCode: 0, output: "" }),
        ffprobe: () => JSON.stringify({ exitCode: 0, output: "" }),
        udpBind: () => JSON.stringify({ socketId: "U1", port: 0 }),
        udpSend: () => null,
        udpClose: () => null,
        tlsListen: () => JSON.stringify({ listenerId: "T1", port: 0 }),
        tlsConnect: () => JSON.stringify({ connectionId: "TC1", peerCertBase64: "" }),
        tlsWrite: () => null,
        tlsClose: () => null,
        tlsStopListening: () => null,
        cryptoGenerateRsaKeyPair: () => JSON.stringify({ privateKeyPem: "", publicKeyPem: "" }),
        cryptoSignSha256: () => "",
    };

    return mockHost;
}

describe("mobile worker runTask", () => {

    afterEach(() => {
        globalThis.host = undefined;
    });

    test("dispatches a handler through runTask, routing context through the host", async () => {
        const mockHost = createMockHost("session-abc");
        globalThis.host = mockHost;

        //
        // Representative handler that exercises every part of the host-backed context.
        //
        registerHandler("test-context-echo", async (data: any, context: ITaskContext) => {
            context.sendMessage({ progress: data.value });
            const cancelled = context.isCancelled();
            return {
                sessionId: context.sessionId,
                taskId: context.taskId,
                cancelled,
                echoed: data.value,
            };
        });

        const resultJson = await runTask("task-1", "test-context-echo", JSON.stringify({ value: 42 }));
        const result = JSON.parse(resultJson);

        // The handler result round-trips back as JSON.
        expect(result.echoed).toBe(42);
        expect(result.taskId).toBe("task-1");

        // sessionId from the host reaches the context.
        expect(result.sessionId).toBe("session-abc");

        // sendMessage routes through the host with the task id and JSON-encoded message.
        expect(mockHost.sentMessages).toEqual([
            { taskId: "task-1", messageJson: JSON.stringify({ progress: 42 }) },
        ]);

        // isCancelled routes through the host with the task id.
        expect(mockHost.cancelledChecks).toEqual(["task-1"]);
        expect(result.cancelled).toBe(false);
    });

    test("rejects when the native host bridge is not installed", async () => {
        globalThis.host = undefined;
        registerHandler("test-noop", async () => ({}));

        await expect(runTask("task-2", "test-noop", "{}"))
            .rejects.toThrow("Native host bridge (globalThis.host) is not installed before runTask was called.");
    });

    test("installWorkerGlobal exposes a working runTask on globalThis.__photosphereWorker", async () => {
        globalThis.__photosphereWorker = undefined;
        installWorkerGlobal();

        expect(globalThis.__photosphereWorker).toBeDefined();
        expect(typeof globalThis.__photosphereWorker!.runTask).toBe("function");

        const mockHost = createMockHost("session-install");
        globalThis.host = mockHost;
        registerHandler("test-install-echo", async (data: any, context: ITaskContext) => {
            return { sessionId: context.sessionId, echoed: data.value };
        });

        const resultJson = await globalThis.__photosphereWorker!.runTask("task-install", "test-install-echo", JSON.stringify({ value: 7 }));
        const result = JSON.parse(resultJson);
        expect(result.echoed).toBe(7);
        expect(result.sessionId).toBe("session-install");

        globalThis.__photosphereWorker = undefined;
    });
});

describe("mobile worker subtask queue backend", () => {

    // installWorkerGlobal installs the process-level worker queue backend once; it is safe to call
    // repeatedly (guarded internally) so each test can rely on it being present.
    beforeEach(() => {
        installWorkerGlobal();
    });

    afterEach(() => {
        globalThis.host = undefined;
    });

    test("a handler enqueuing a child task routes it to host.queueTask", () => {
        const mockHost = createMockHost("session-queue");
        globalThis.host = mockHost;

        const queue = new TaskQueue(new RandomUuidGenerator(), "import-source");
        const childId = queue.addTask("hash-file", { filePath: "cat.jpg" });

        expect(mockHost.queuedTasks).toEqual([
            { taskId: childId, type: "hash-file", dataJson: JSON.stringify({ filePath: "cat.jpg" }), source: "import-source" },
        ]);

        queue.shutdown();
    });

    test("a delivered child completion resolves the awaiting orchestrator", async () => {
        const mockHost = createMockHost("session-queue");
        globalThis.host = mockHost;

        const queue = new TaskQueue(new RandomUuidGenerator(), "import-source-2");
        const childId = queue.addTask("hash-file", { filePath: "dog.jpg" });
        const resultPromise = queue.awaitTask(childId);

        deliverChildEvent(JSON.stringify({
            kind: "completed",
            result: {
                taskId: childId,
                status: TaskStatus.Succeeded,
                type: "hash-file",
                inputs: { filePath: "dog.jpg" },
                outputs: { hash: "abc123" },
            },
        }));

        const result = await resultPromise;
        expect(result?.status).toBe(TaskStatus.Succeeded);
        expect(result?.outputs.hash).toBe("abc123");

        queue.shutdown();
    });

    test("a delivered child failure reconstructs an Error on the result", async () => {
        const mockHost = createMockHost("session-queue");
        globalThis.host = mockHost;

        const queue = new TaskQueue(new RandomUuidGenerator(), "import-source-3");
        const childId = queue.addTask("hash-file", { filePath: "bad.jpg" });
        const resultPromise = queue.awaitTask(childId);

        deliverChildEvent(JSON.stringify({
            kind: "completed",
            result: {
                taskId: childId,
                status: TaskStatus.Failed,
                type: "hash-file",
                inputs: { filePath: "bad.jpg" },
                errorMessage: "hashing failed",
            },
        }));

        const result = await resultPromise;
        expect(result?.status).toBe(TaskStatus.Failed);
        expect(result?.errorMessage).toBe("hashing failed");
        expect(result?.error).toBeInstanceOf(Error);
        expect(result?.error?.message).toBe("hashing failed");

        queue.shutdown();
    });

    test("binary (Uint8Array) and Date fields survive the bridge round trip", async () => {
        const mockHost = createMockHost("session-binary");
        globalThis.host = mockHost;

        // A handler that returns a Uint8Array and a Date (e.g. hash-file's hash + a stat time).
        registerHandler("test-binary-result", async () => {
            return { hash: new Uint8Array([1, 2, 3, 255]), when: new Date(1234567890) };
        });

        // runTask serialises the result; binary/Date must be encoded so plain JSON can carry them.
        const resultJson = await runTask("bin-task", "test-binary-result", "{}");
        expect(resultJson).toContain("__u8b64__");
        expect(resultJson).toContain("__date__");

        // Delivering that result as a child completion must reconstruct a Buffer and a Date so the
        // orchestrator (which does Buffer.from(hash) and lastModified.getTime()) works.
        const queue = new TaskQueue(new RandomUuidGenerator(), "bin-source");
        const childId = queue.addTask("test-binary-result", {});
        const resultPromise = queue.awaitTask(childId);

        deliverChildEvent(JSON.stringify({
            kind: "completed",
            result: {
                taskId: childId,
                status: TaskStatus.Succeeded,
                type: "test-binary-result",
                inputs: {},
                outputs: JSON.parse(resultJson),
            },
        }));

        const result = await resultPromise;
        expect(Buffer.isBuffer(result?.outputs.hash)).toBe(true);
        expect(Array.from(result?.outputs.hash as Buffer)).toEqual([1, 2, 3, 255]);
        expect(result?.outputs.when instanceof Date).toBe(true);
        expect((result?.outputs.when as Date).getTime()).toBe(1234567890);

        queue.shutdown();
    });

    test("a delivered child message fires the orchestrator's message callback", async () => {
        const mockHost = createMockHost("session-queue");
        globalThis.host = mockHost;

        const queue = new TaskQueue(new RandomUuidGenerator(), "import-source-4");
        const childId = queue.addTask("hash-file", { filePath: "cat.jpg" });

        const received: any[] = [];
        queue.onTaskMessage("progress", ({ message }) => {
            received.push(message);
        });

        deliverChildEvent(JSON.stringify({
            kind: "message",
            taskId: childId,
            message: { type: "progress", percent: 50 },
        }));

        // notifyTaskMessage is async; allow the microtask queue to drain.
        await Promise.resolve();

        expect(received).toEqual([{ type: "progress", percent: 50 }]);

        queue.shutdown();
    });
});
