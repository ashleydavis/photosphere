import { WorkerQueueBackend } from "../src/lib/worker-queue-backend";
import { TaskStatus } from "../src/lib/types";
import type { ITaskResult } from "../src/lib/types";

describe("WorkerQueueBackend", () => {
    let postMessage: jest.Mock;
    let backend: WorkerQueueBackend;

    beforeEach(() => {
        postMessage = jest.fn();
        backend = new WorkerQueueBackend(postMessage);
    });

    test("addTask calls postMessage with { type, taskId, taskType, data, source }", () => {
        backend.addTask("my-type", { foo: 1 }, "my-source", "my-task-id");

        expect(postMessage).toHaveBeenCalledWith({
            type: "queue-task",
            taskId: "my-task-id",
            taskType: "my-type",
            data: { foo: 1 },
            source: "my-source",
        });
    });

    test("onTaskComplete unsubscribe removes only that callback", async () => {
        const firedA: ITaskResult[] = [];
        const firedB: ITaskResult[] = [];
        const unsubA = backend.onTaskComplete((result) => { firedA.push(result); });
        backend.onTaskComplete((result) => { firedB.push(result); });

        unsubA();

        const taskResult: ITaskResult = {
            taskId: "task-1",
            type: "my-type",
            inputs: {},
            status: TaskStatus.Succeeded,
        };
        await backend.notifyTaskCompleted(taskResult);

        expect(firedA).toHaveLength(0);
        expect(firedB).toHaveLength(1);
    });

    test("onTaskComplete callback fires when notifyTaskCompleted is called", async () => {
        const results: ITaskResult[] = [];
        backend.onTaskComplete((result) => { results.push(result); });

        const taskResult: ITaskResult = {
            taskId: "task-1",
            type: "my-type",
            inputs: {},
            status: TaskStatus.Succeeded,
            outputs: "done",
        };
        await backend.notifyTaskCompleted(taskResult);

        expect(results).toHaveLength(1);
        expect(results[0]).toBe(taskResult);
    });

    test("onTaskAdded unsubscribe removes only that callback", () => {
        const firedA: string[] = [];
        const firedB: string[] = [];
        const unsubA = backend.onTaskAdded("src", (id) => firedA.push(id));
        backend.onTaskAdded("src", (id) => firedB.push(id));

        unsubA();
        backend.addTask("t", {}, "src", "task-1");

        expect(firedA).toHaveLength(0);
        expect(firedB).toEqual(["task-1"]);
    });

    test("shutdown does not throw", () => {
        expect(() => backend.shutdown()).not.toThrow();
    });

    test("onTasksCancelled unsubscribe removes only that callback", () => {
        const firedA: number[] = [];
        const firedB: number[] = [];
        const unsubA = backend.onTasksCancelled("src", () => firedA.push(1));
        backend.onTasksCancelled("src", () => firedB.push(1));

        unsubA();
        backend.cancelTasks("src");

        expect(firedA).toHaveLength(0);
        expect(firedB).toHaveLength(1);
    });

    test("cancelTasks fires onTasksCancelled callbacks registered for that source", () => {
        const firedA: number[] = [];
        const firedB: number[] = [];
        backend.onTasksCancelled("source-a", () => firedA.push(1));
        backend.onTasksCancelled("source-b", () => firedB.push(1));

        backend.cancelTasks("source-a");

        expect(firedA).toHaveLength(1);
        expect(firedB).toHaveLength(0);
    });

    test("onAnyTaskMessage unsubscribe removes only that callback", async () => {
        const firedA: any[] = [];
        const firedB: any[] = [];
        const unsubA = backend.onAnyTaskMessage((data) => { firedA.push(data); });
        backend.onAnyTaskMessage((data) => { firedB.push(data); });

        unsubA();
        await backend.notifyTaskMessage("task-1", { type: "foo" });

        expect(firedA).toHaveLength(0);
        expect(firedB).toHaveLength(1);
    });

    test("onAnyTaskMessage callback fires for all messages regardless of type", async () => {
        const fired: any[] = [];
        backend.onAnyTaskMessage((data) => { fired.push(data); });

        await backend.notifyTaskMessage("task-1", { type: "foo" });
        await backend.notifyTaskMessage("task-2", { type: "bar" });
        await backend.notifyTaskMessage("task-3", { type: "baz" });

        expect(fired).toHaveLength(3);
        expect(fired[0].taskId).toBe("task-1");
        expect(fired[1].taskId).toBe("task-2");
        expect(fired[2].taskId).toBe("task-3");
    });

    test("onTaskMessage unsubscribe removes only that callback", async () => {
        const firedA: any[] = [];
        const firedB: any[] = [];
        const unsubA = backend.onTaskMessage("foo", (data) => { firedA.push(data); });
        backend.onTaskMessage("foo", (data) => { firedB.push(data); });

        unsubA();
        await backend.notifyTaskMessage("task-1", { type: "foo" });

        expect(firedA).toHaveLength(0);
        expect(firedB).toHaveLength(1);
    });

    test("onTaskMessage callback fires only when the message type matches", async () => {
        const firedFoo: any[] = [];
        const firedBar: any[] = [];
        backend.onTaskMessage("foo", (data) => { firedFoo.push(data); });
        backend.onTaskMessage("bar", (data) => { firedBar.push(data); });

        await backend.notifyTaskMessage("task-1", { type: "foo", value: 1 });

        expect(firedFoo).toHaveLength(1);
        expect(firedBar).toHaveLength(0);
    });

    test("addTask fires onTaskAdded callbacks registered for the matching source", () => {
        const firedIds: string[] = [];
        backend.onTaskAdded("source-a", (taskId) => firedIds.push(taskId));

        backend.addTask("my-type", {}, "source-a", "task-1");
        backend.addTask("my-type", {}, "source-b", "task-2");

        expect(firedIds).toEqual(["task-1"]);
    });
});
