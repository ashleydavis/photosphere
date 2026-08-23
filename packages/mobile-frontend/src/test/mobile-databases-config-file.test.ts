import type { IQueueBackend, ITaskResult, TaskMessageCallback, UnsubscribeFn, WorkerTaskCompletionCallback } from "task-queue";
import { setQueueBackend, TaskPriority, TaskStatus } from "task-queue";
import { DATABASES_CONFIG_PATH, mobileDatabasesConfigFile } from "../lib/mobile-databases-config-file";

//
// What one call to addTask was given, so a test can assert on the priority it asked for.
//
interface IRecordedTask {
    // The handler name.
    type: string;

    // The input data.
    data: any;

    // The priority asked for, or undefined when none was named.
    priority: TaskPriority | undefined;
}

//
// A queue backend that records every task added and completes it immediately with the outputs it was
// given. The config file only queues a task and waits for it, so this is the whole of what it needs.
//
class RecordingBackend implements IQueueBackend {
    //
    // Every task added through this backend, in order.
    //
    readonly addedTasks: IRecordedTask[] = [];

    //
    // The outputs every completed task reports.
    //
    private readonly outputs: any;

    //
    // Callbacks registered per source, fired when a task with that source is added.
    //
    private taskAddedCallbacks: Map<string, ((taskId: string) => void)[]> = new Map();

    //
    // Callbacks fired when a task completes.
    //
    private completionCallbacks: WorkerTaskCompletionCallback[] = [];

    constructor(outputs: any) {
        this.outputs = outputs;
    }

    addTask(type: string, data: any, source: string, taskId?: string, priority?: TaskPriority): string {
        const id = taskId ?? "generated-id";
        this.addedTasks.push({ type, data, priority });

        const callbacks = this.taskAddedCallbacks.get(source);
        if (callbacks) {
            for (const callback of callbacks) {
                callback(id);
            }
        }

        const result: ITaskResult = {
            taskId: id,
            status: TaskStatus.Succeeded,
            outputs: this.outputs,
            type,
            inputs: data,
        };
        // Completed on a microtask so the caller has returned from addTask and is awaiting the task
        // before its result arrives, which is the order the real bridge produces.
        Promise.resolve().then(() => {
            for (const callback of [...this.completionCallbacks]) {
                void callback(result);
            }
        });

        return id;
    }

    onTaskAdded(source: string, callback: (taskId: string) => void): UnsubscribeFn {
        const existing = this.taskAddedCallbacks.get(source) ?? [];
        existing.push(callback);
        this.taskAddedCallbacks.set(source, existing);
        return () => { /* nothing to unsubscribe in a test. */ };
    }

    onTaskComplete(callback: WorkerTaskCompletionCallback): UnsubscribeFn {
        this.completionCallbacks.push(callback);
        return () => { /* nothing to unsubscribe in a test. */ };
    }

    onTaskMessage(_messageType: string, _callback: TaskMessageCallback): UnsubscribeFn {
        return () => { /* nothing subscribed. */ };
    }

    onAnyTaskMessage(_callback: TaskMessageCallback): UnsubscribeFn {
        return () => { /* nothing subscribed. */ };
    }

    cancelTasks(_source: string): void {
        // Nothing to cancel.
    }

    onTasksCancelled(_source: string, _callback: () => void): UnsubscribeFn {
        return () => { /* nothing subscribed. */ };
    }

    shutdown(): void {
        // Nothing to shut down.
    }
}

describe("mobileDatabasesConfigFile", () => {

    test("reads the config as interactive, because nothing can be listed or opened until it returns", async () => {
        const backend = new RecordingBackend({ databases: [], recentDatabaseNames: [] });
        setQueueBackend(backend);

        await mobileDatabasesConfigFile.read();

        expect(backend.addedTasks).toHaveLength(1);
        expect(backend.addedTasks[0].type).toBe("read-databases-config");
        expect(backend.addedTasks[0].priority).toBe(TaskPriority.Interactive);
    });

    test("writes the config as interactive too, because the user is waiting on the write to land", async () => {
        const backend = new RecordingBackend({});
        setQueueBackend(backend);

        await mobileDatabasesConfigFile.write({ databases: [], recentDatabaseNames: ["one"] });

        expect(backend.addedTasks).toHaveLength(1);
        expect(backend.addedTasks[0].type).toBe("write-databases-config");
        expect(backend.addedTasks[0].priority).toBe(TaskPriority.Interactive);
    });

    test("names the sandbox-relative config path in the task data", async () => {
        const backend = new RecordingBackend({ databases: [], recentDatabaseNames: [] });
        setQueueBackend(backend);

        await mobileDatabasesConfigFile.read();

        expect(backend.addedTasks[0].data).toEqual({ configPath: DATABASES_CONFIG_PATH });
    });
});
