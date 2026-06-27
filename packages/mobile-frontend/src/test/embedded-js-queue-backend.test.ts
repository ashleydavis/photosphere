import { EmbeddedJsQueueBackend } from "../lib/embedded-js-queue-backend";
import type { IJsEnginePlugin, ITaskCompletedEvent, ITaskMessageEvent } from "../lib/js-engine-plugin";
import type { ITaskResult } from "task-queue";
import { TaskStatus } from "task-queue";

//
// A deferred promise helper so tests can control when a mocked bridge call settles.
//
interface IDeferred<T> {
    // The pending promise.
    promise: Promise<T>;
    // Resolves the promise.
    resolve: (value: T) => void;
    // Rejects the promise.
    reject: (error: any) => void;
}

//
// Creates a deferred promise.
//
function makeDeferred<T>(): IDeferred<T> {
    let resolve!: (value: T) => void;
    let reject!: (error: any) => void;
    const promise = new Promise<T>((res, rej) => {
        resolve = res;
        reject = rej;
    });
    return { promise, resolve, reject };
}

//
// A mock JsEngine plugin that records calls and lets tests emit events.
//
interface IMockPlugin extends IJsEnginePlugin {
    // Emits an event to all registered listeners for the channel.
    _emit(eventName: "taskCompleted", payload: ITaskCompletedEvent): void;
    _emit(eventName: "taskMessage", payload: ITaskMessageEvent): void;
    // The list of channels whose handles have had remove() called.
    _removed: string[];
    // The mock addTask function.
    addTask: jest.Mock;
    // The mock cancelTasks function.
    cancelTasks: jest.Mock;
    // The mock shutdown function.
    shutdown: jest.Mock;
}

//
// Builds a mock JsEngine plugin.
//
function makeMockPlugin(): IMockPlugin {
    const listeners: Map<string, ((event: any) => void)[]> = new Map();
    const removed: string[] = [];

    const plugin: any = {
        addTask: jest.fn().mockResolvedValue(undefined),
        cancelTasks: jest.fn().mockResolvedValue(undefined),
        shutdown: jest.fn().mockResolvedValue(undefined),
        addListener: jest.fn().mockImplementation(async (eventName: string, listenerFunc: (event: any) => void) => {
            const existing = listeners.get(eventName) ?? [];
            existing.push(listenerFunc);
            listeners.set(eventName, existing);
            return {
                remove: jest.fn().mockImplementation(async () => {
                    removed.push(eventName);
                }),
            };
        }),
        _emit(eventName: string, payload: any) {
            for (const listenerFunc of listeners.get(eventName) ?? []) {
                listenerFunc(payload);
            }
        },
        _removed: removed,
    };

    return plugin as IMockPlugin;
}

describe("EmbeddedJsQueueBackend", () => {
    test("addTask returns the id synchronously and forwards the right payload", () => {
        const plugin = makeMockPlugin();
        const backend = new EmbeddedJsQueueBackend(plugin);

        const id = backend.addTask("hash-file", { path: "a.jpg" }, "db-1", "task-1");

        expect(id).toBe("task-1");
        expect(plugin.addTask).toHaveBeenCalledWith({ taskId: "task-1", type: "hash-file", data: { path: "a.jpg" }, source: "db-1" });
    });

    test("addTask generates an id when none is supplied", () => {
        const plugin = makeMockPlugin();
        const backend = new EmbeddedJsQueueBackend(plugin);

        const id = backend.addTask("hash-file", {}, "db-1");

        expect(typeof id).toBe("string");
        expect(id.length).toBeGreaterThan(0);
    });

    test("addTask fires onTaskAdded callbacks for the source", () => {
        const plugin = makeMockPlugin();
        const backend = new EmbeddedJsQueueBackend(plugin);
        const added: string[] = [];
        backend.onTaskAdded("db-1", id => added.push(id));

        backend.addTask("hash-file", {}, "db-1", "task-1");

        expect(added).toEqual(["task-1"]);
    });

    test("a simulated taskCompleted event fires completion callbacks", async () => {
        const plugin = makeMockPlugin();
        const backend = new EmbeddedJsQueueBackend(plugin);
        await backend.init();

        const results: ITaskResult[] = [];
        backend.onTaskComplete(result => { results.push(result); });

        plugin._emit("taskCompleted", {
            taskId: "task-1",
            result: { taskId: "task-1", status: TaskStatus.Succeeded, type: "hash-file", inputs: {}, outputs: { hash: "abc" } },
        });
        await Promise.resolve();

        expect(results).toHaveLength(1);
        expect(results[0].taskId).toBe("task-1");
        expect(results[0].status).toBe(TaskStatus.Succeeded);
        expect(results[0].outputs).toEqual({ hash: "abc" });
    });

    test("a failed taskCompleted event reconstructs an Error on the result", async () => {
        const plugin = makeMockPlugin();
        const backend = new EmbeddedJsQueueBackend(plugin);
        await backend.init();

        const results: ITaskResult[] = [];
        backend.onTaskComplete(result => { results.push(result); });

        plugin._emit("taskCompleted", {
            taskId: "task-1",
            result: { taskId: "task-1", status: TaskStatus.Failed, type: "hash-file", inputs: {}, errorMessage: "boom" },
        });
        await Promise.resolve();

        expect(results[0].status).toBe(TaskStatus.Failed);
        expect(results[0].error).toBeInstanceOf(Error);
        expect(results[0].errorMessage).toBe("boom");
    });

    test("a simulated taskMessage event fires type-filtered and any callbacks", async () => {
        const plugin = makeMockPlugin();
        const backend = new EmbeddedJsQueueBackend(plugin);
        await backend.init();

        const typed: any[] = [];
        const any: any[] = [];
        backend.onTaskMessage("progress", data => { typed.push(data); });
        backend.onTaskMessage("other", data => { typed.push(data); });
        backend.onAnyTaskMessage(data => { any.push(data); });

        plugin._emit("taskMessage", { taskId: "task-1", message: { type: "progress", value: 50 } });
        await Promise.resolve();

        expect(typed).toHaveLength(1);
        expect(typed[0].message.value).toBe(50);
        expect(any).toHaveLength(1);
    });

    test("cancelTasks forwards to the plugin and fires onTasksCancelled", () => {
        const plugin = makeMockPlugin();
        const backend = new EmbeddedJsQueueBackend(plugin);
        let cancelled = false;
        backend.onTasksCancelled("db-1", () => { cancelled = true; });

        backend.cancelTasks("db-1");

        expect(plugin.cancelTasks).toHaveBeenCalledWith({ source: "db-1" });
        expect(cancelled).toBe(true);
    });

    test("addTask is fire-and-forget: returns before the bridge promise settles", async () => {
        const plugin = makeMockPlugin();
        const deferred = makeDeferred<void>();
        plugin.addTask.mockReturnValueOnce(deferred.promise);
        const backend = new EmbeddedJsQueueBackend(plugin);

        const id = backend.addTask("hash-file", {}, "db-1", "task-1");

        // The id is returned synchronously even though the bridge promise is still pending.
        expect(id).toBe("task-1");
        deferred.resolve();
        await deferred.promise;
    });

    test("a bridge rejection synthesises a taskCompleted error result", async () => {
        const plugin = makeMockPlugin();
        plugin.addTask.mockRejectedValueOnce(new Error("bridge down"));
        const backend = new EmbeddedJsQueueBackend(plugin);
        await backend.init();

        const results: ITaskResult[] = [];
        backend.onTaskComplete(result => { results.push(result); });

        backend.addTask("hash-file", {}, "db-1", "task-1");
        // Flush the rejected-promise microtask chain.
        await Promise.resolve();
        await Promise.resolve();

        expect(results).toHaveLength(1);
        expect(results[0].taskId).toBe("task-1");
        expect(results[0].status).toBe(TaskStatus.Failed);
        expect(results[0].errorMessage).toBe("bridge down");
    });

    test("init awaits both addListener handles before resolving", async () => {
        const plugin = makeMockPlugin();
        const backend = new EmbeddedJsQueueBackend(plugin);

        await backend.init();

        expect(plugin.addListener).toHaveBeenCalledTimes(2);
        expect(plugin.addListener).toHaveBeenCalledWith("taskCompleted", expect.any(Function));
        expect(plugin.addListener).toHaveBeenCalledWith("taskMessage", expect.any(Function));
    });

    test("a completion callback registered before init still receives a later event", async () => {
        const plugin = makeMockPlugin();
        const backend = new EmbeddedJsQueueBackend(plugin);
        const results: ITaskResult[] = [];

        // Register the completion callback before init (mirrors native buffer/flush timing).
        backend.onTaskComplete(result => { results.push(result); });
        await backend.init();

        plugin._emit("taskCompleted", {
            taskId: "task-1",
            result: { taskId: "task-1", status: TaskStatus.Succeeded, type: "hash-file", inputs: {} },
        });
        await Promise.resolve();

        expect(results).toHaveLength(1);
    });

    test("shutdown removes every listener handle and calls plugin.shutdown", async () => {
        const plugin = makeMockPlugin();
        const backend = new EmbeddedJsQueueBackend(plugin);
        await backend.init();

        backend.shutdown();
        await Promise.resolve();

        expect(plugin._removed).toEqual(["taskCompleted", "taskMessage"]);
        expect(plugin.shutdown).toHaveBeenCalledTimes(1);
    });
});
