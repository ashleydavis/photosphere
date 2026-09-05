import type { IQueueBackend, ITaskResult, TaskMessageCallback, UnsubscribeFn, WorkerTaskCompletionCallback } from "task-queue";
import { setQueueBackend, TaskPriority, TaskStatus } from "task-queue";
import { runResetAppStorageTask } from "../../lib/reset-app-storage-task";

//
// What one call to addTask was given, so a test can assert on the task it asked for.
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
// A queue backend that records every task added and completes it immediately with the status and
// outputs it was built with. Running the reset only queues a task and waits for it, so this is the
// whole of what it needs.
//
class RecordingBackend implements IQueueBackend {
    //
    // Every task added through this backend, in order.
    //
    readonly addedTasks: IRecordedTask[] = [];

    //
    // The status every completed task reports.
    //
    private readonly status: TaskStatus;

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

    constructor(status: TaskStatus, outputs: any) {
        this.status = status;
        this.outputs = outputs;
    }

    addTask(type: string, data: any, source: string, taskId?: string, priority?: TaskPriority): string {
        const id = taskId ?? "generated-id";
        this.addedTasks.push({
            type,
            data,
            priority,
        });

        const callbacks = this.taskAddedCallbacks.get(source);
        if (callbacks) {
            for (const callback of callbacks) {
                callback(id);
            }
        }

        const result: ITaskResult = {
            taskId: id,
            status: this.status,
            outputs: this.outputs,
            errorMessage: this.status === TaskStatus.Failed ? "the storage could not be emptied" : undefined,
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

describe("runResetAppStorageTask", () => {

    test("queues the reset as interactive, with no path for it to act on", async () => {
        const backend = new RecordingBackend(TaskStatus.Succeeded, {
            entriesRemoved: 3,
        });
        setQueueBackend(backend);

        await runResetAppStorageTask();

        expect(backend.addedTasks).toHaveLength(1);
        expect(backend.addedTasks[0].type).toBe("reset-app-storage");
        expect(backend.addedTasks[0].priority).toBe(TaskPriority.Interactive);
        expect(backend.addedTasks[0].data).toEqual({});
    });

    test("reports how many entries the task removed", async () => {
        const backend = new RecordingBackend(TaskStatus.Succeeded, {
            entriesRemoved: 3,
        });
        setQueueBackend(backend);

        const outcome = await runResetAppStorageTask();

        expect(outcome).toEqual({
            entriesRemoved: 3,
        });
    });

    test("reports nothing removed when the task says nothing", async () => {
        const backend = new RecordingBackend(TaskStatus.Succeeded, {});
        setQueueBackend(backend);

        const outcome = await runResetAppStorageTask();

        expect(outcome).toEqual({
            entriesRemoved: 0,
        });
    });

    test("throws when the task fails, rather than reporting a reset that did not happen", async () => {
        const backend = new RecordingBackend(TaskStatus.Failed, undefined);
        setQueueBackend(backend);

        await expect(runResetAppStorageTask()).rejects.toThrow("the storage could not be emptied");
    });
});
