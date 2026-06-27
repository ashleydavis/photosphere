import { cancelMobileTasks, subscribeMobileTaskMessage, subscribeMobileTaskComplete } from "../lib/mobile-platform-tasks";
import type { IJsEnginePlugin } from "../lib/js-engine-plugin";

//
// Builds a mock JsEngine plugin that records calls and lets tests emit events.
//
function makeMockPlugin() {
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

    return plugin as IJsEnginePlugin & { _emit(eventName: string, payload: any): void; _removed: string[]; cancelTasks: jest.Mock };
}

describe("mobile platform task bindings", () => {
    test("cancelMobileTasks forwards to JsEngine.cancelTasks", async () => {
        const plugin = makeMockPlugin();

        await cancelMobileTasks("db-1", plugin);

        expect(plugin.cancelTasks).toHaveBeenCalledWith({ source: "db-1" });
    });

    test("subscribeMobileTaskMessage fires the handler on a taskMessage event", async () => {
        const plugin = makeMockPlugin();
        const received: any[] = [];

        const unsubscribe = subscribeMobileTaskMessage((taskId, message) => {
            received.push({ taskId, message });
        }, plugin);
        // Let the async addListener resolve.
        await Promise.resolve();

        plugin._emit("taskMessage", { taskId: "task-1", message: { type: "progress", value: 10 } });

        expect(received).toHaveLength(1);
        expect(received[0].taskId).toBe("task-1");
        expect(received[0].message).toEqual({ type: "progress", value: 10 });

        unsubscribe();
        await Promise.resolve();
        expect(plugin._removed).toContain("taskMessage");
    });

    test("subscribeMobileTaskComplete fires the handler on a taskCompleted event", async () => {
        const plugin = makeMockPlugin();
        const received: any[] = [];

        subscribeMobileTaskComplete((taskId, result) => {
            received.push({ taskId, result });
        }, plugin);
        await Promise.resolve();

        plugin._emit("taskCompleted", { taskId: "task-1", result: { taskId: "task-1", status: "succeeded", type: "hash-file", inputs: {} } });

        expect(received).toHaveLength(1);
        expect(received[0].taskId).toBe("task-1");
        expect(received[0].result.status).toBe("succeeded");
    });
});
