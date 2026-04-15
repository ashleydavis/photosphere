import { setQueueBackend, getQueueBackend } from "../src/lib/queue-backend";
import type { IQueueBackend } from "../src/lib/queue-backend";

//
// Minimal no-op backend for testing the singleton helpers.
//
function makeBackend(): IQueueBackend {
    return {
        addTask: jest.fn().mockReturnValue("task-id"),
        onTaskAdded: jest.fn().mockReturnValue(() => {}),
        onTaskComplete: jest.fn().mockReturnValue(() => {}),
        onTaskMessage: jest.fn().mockReturnValue(() => {}),
        onAnyTaskMessage: jest.fn().mockReturnValue(() => {}),
        cancelTasks: jest.fn(),
        onTasksCancelled: jest.fn().mockReturnValue(() => {}),
        shutdown: jest.fn(),
    };
}

describe("queue-backend singleton", () => {
    afterEach(() => {
        // Reset to a fresh backend so later tests start clean.
        setQueueBackend(makeBackend());
    });

    test("getQueueBackend throws before setQueueBackend is called", () => {
        // Force the singleton to undefined so getQueueBackend throws.
        setQueueBackend(undefined as any);
        expect(() => getQueueBackend()).toThrow();
    });

    test("getQueueBackend returns the backend set by setQueueBackend", () => {
        const backend = makeBackend();
        setQueueBackend(backend);
        expect(getQueueBackend()).toBe(backend);
    });

    test("calling setQueueBackend a second time replaces the previously registered backend", () => {
        const backend1 = makeBackend();
        const backend2 = makeBackend();
        setQueueBackend(backend1);
        setQueueBackend(backend2);
        expect(getQueueBackend()).toBe(backend2);
        expect(getQueueBackend()).not.toBe(backend1);
    });
});
