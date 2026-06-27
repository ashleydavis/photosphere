import { registerHandler, ITaskContext } from "task-queue";
import { runTask, installWorkerGlobal } from "../lib/mobile-worker-runtime";
import { IHost } from "../lib/host-functions";

//
// Builds a mock native host bridge for the tests, capturing calls to
// sendMessage / isCancelled so the tests can assert routing.
//
interface IMockHost extends IHost {
    // Records every (taskId, messageJson) passed to sendMessage.
    sentMessages: Array<{ taskId: string; messageJson: string }>;

    // Records every taskId passed to isCancelled.
    cancelledChecks: string[];
}

function createMockHost(sessionId: string): IMockHost {
    const sentMessages: Array<{ taskId: string; messageJson: string }> = [];
    const cancelledChecks: string[] = [];
    const mockHost: IMockHost = {
        platform: "android",
        sessionId,
        sentMessages,
        cancelledChecks,
        sendMessage: (taskId: string, messageJson: string) => {
            sentMessages.push({ taskId, messageJson });
        },
        isCancelled: (taskId: string) => {
            cancelledChecks.push(taskId);
            return false;
        },
        sha256: (path: string) => `sha256(${path})`,
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
