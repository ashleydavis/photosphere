import type { ITaskContext } from "task-queue";
import { receiveShareHandler, findReceiverHandler, sendPayloadHandler } from "../lib/lan-share-handlers";

//
// Builds a minimal ITaskContext whose isCancelled is driven by the supplied getter.
//
function makeContext(isCancelled: () => boolean): ITaskContext {
    return {
        uuidGenerator: { generate: () => "test-uuid" },
        timestampProvider: { now: () => 0, dateNow: () => new Date(0) },
        sessionId: "session-1",
        taskId: "task-1",
        sendMessage: () => { /* no-op */ },
        isCancelled,
    };
}

describe("mobile lan-share handlers", () => {
    afterEach(() => {
        jest.useRealTimers();
    });

    test("receiveShareHandler stays pending until the timeout, then resolves with a null payload", async () => {
        jest.useFakeTimers();
        const context = makeContext(() => false);

        const promise = receiveShareHandler({}, context);

        let resolved = false;
        void promise.then(() => { resolved = true; });

        // Still pending well before the 60s timeout.
        jest.advanceTimersByTime(30000);
        await Promise.resolve();
        expect(resolved).toBe(false);

        // Resolves once the full timeout elapses.
        jest.advanceTimersByTime(30000);
        const result = await promise;
        expect(result).toEqual({ payload: null });
    });

    test("receiveShareHandler resolves early when the task is cancelled", async () => {
        jest.useFakeTimers();
        let cancelled = false;
        const context = makeContext(() => cancelled);

        const promise = receiveShareHandler({}, context);

        cancelled = true;
        // Advancing past one poll interval lets the cancellation watcher fire.
        jest.advanceTimersByTime(300);
        const result = await promise;
        expect(result).toEqual({ payload: null });
    });

    test("findReceiverHandler stays pending until the timeout, then resolves with a null endpoint", async () => {
        jest.useFakeTimers();
        const context = makeContext(() => false);

        const promise = findReceiverHandler({ code: "1234" }, context);

        let resolved = false;
        void promise.then(() => { resolved = true; });

        jest.advanceTimersByTime(30000);
        await Promise.resolve();
        expect(resolved).toBe(false);

        jest.advanceTimersByTime(30000);
        const result = await promise;
        expect(result).toEqual({ endpoint: null });
    });

    test("findReceiverHandler resolves early when the task is cancelled", async () => {
        jest.useFakeTimers();
        let cancelled = false;
        const context = makeContext(() => cancelled);

        const promise = findReceiverHandler({ code: "1234" }, context);

        cancelled = true;
        jest.advanceTimersByTime(300);
        const result = await promise;
        expect(result).toEqual({ endpoint: null });
    });

    test("sendPayloadHandler reports failure immediately without waiting", async () => {
        const result = await sendPayloadHandler({});
        expect(result).toEqual({ success: false });
    });
});
