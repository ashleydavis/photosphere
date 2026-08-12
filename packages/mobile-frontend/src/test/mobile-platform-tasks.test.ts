import { cancelMobileTasks, publishLocalTaskMessage, subscribeMobileTaskMessage, subscribeMobileTaskComplete, pickMobileFiles, setInjectedPickedFiles } from "../lib/mobile-platform-tasks";
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
        pickFiles: jest.fn().mockResolvedValue({ paths: [] }),
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

    test("pickMobileFiles returns the plugin's picked paths", async () => {
        const plugin = makeMockPlugin();
        (plugin.pickFiles as jest.Mock).mockResolvedValue({ paths: [".import-tmp/a.jpg", ".import-tmp/b.png"] });

        const paths = await pickMobileFiles("Import photos", plugin);

        expect(plugin.pickFiles).toHaveBeenCalledWith({ title: "Import photos" });
        expect(paths).toEqual([".import-tmp/a.jpg", ".import-tmp/b.png"]);
    });

    test("pickMobileFiles returns undefined when the user picked nothing", async () => {
        const plugin = makeMockPlugin();
        (plugin.pickFiles as jest.Mock).mockResolvedValue({ paths: [] });

        const paths = await pickMobileFiles("Import photos", plugin);

        expect(paths).toBeUndefined();
    });

    test("a message produced in the WebView reaches the same subscribers as a native one", async () => {
        const plugin = makeMockPlugin();
        const received: { taskId: string, message: Record<string, unknown> }[] = [];
        subscribeMobileTaskMessage((taskId, message) => received.push({ taskId, message }), plugin as unknown as IJsEnginePlugin);

        // Automatic import runs in the WebView rather than in an engine, so its progress arrives
        // this way. The interface that shows it is shared with the desktop and reads task messages.
        publishLocalTaskMessage("session-1", { type: "auto-import-progress", imported: 3 });

        expect(received).toHaveLength(1);
        expect(received[0].taskId).toBe("session-1");
        expect(received[0].message).toEqual({ type: "auto-import-progress", imported: 3 });
    });

    test("an unsubscribed handler stops receiving WebView messages", async () => {
        const plugin = makeMockPlugin();
        const received: Record<string, unknown>[] = [];
        const unsubscribe = subscribeMobileTaskMessage((_taskId, message) => received.push(message), plugin as unknown as IJsEnginePlugin);

        unsubscribe();
        publishLocalTaskMessage("session-1", { type: "auto-import-progress" });

        expect(received).toEqual([]);
    });

    test("pickMobileFiles returns injected test paths without calling the plugin", async () => {
        const plugin = makeMockPlugin();
        setInjectedPickedFiles([".import-tmp/seeded-1.jpeg", ".import-tmp/seeded-2.png"]);

        const paths = await pickMobileFiles("Import photos", plugin);

        expect(plugin.pickFiles).not.toHaveBeenCalled();
        expect(paths).toEqual([".import-tmp/seeded-1.jpeg", ".import-tmp/seeded-2.png"]);

        // Injection is consumed once: the next call falls through to the plugin.
        (plugin.pickFiles as jest.Mock).mockResolvedValue({ paths: [] });
        const second = await pickMobileFiles("Import photos", plugin);
        expect(plugin.pickFiles).toHaveBeenCalledTimes(1);
        expect(second).toBeUndefined();
    });
});
