import { TaskPriority } from "task-queue";
import type { ITaskQueue, ITaskResult, TaskCompletionCallback, TaskMessageCallback, UnsubscribeFn } from "task-queue";
import { loadAssets } from "../../lib/load-assets";

//
// What one call to addTask was given, so a test can assert on the priority it asked for.
//
interface IRecordedTask {
    // The handler name.
    type: string;

    // The input data.
    data: any;

    // The explicit task id, or undefined when the queue was left to mint one.
    taskId: string | undefined;

    // The priority asked for, or undefined when none was named.
    priority: TaskPriority | undefined;
}

//
// A task queue that records what it was asked to add and does nothing else. loadAssets only ever
// queues, so this is the whole of what it touches.
//
class RecordingTaskQueue implements ITaskQueue {
    //
    // Every task added through this queue, in order.
    //
    readonly addedTasks: IRecordedTask[] = [];

    addTask(type: string, data: any, taskId?: string, priority?: TaskPriority): string {
        this.addedTasks.push({ type, data, taskId, priority });
        return taskId ?? "generated-id";
    }

    async awaitAllTasks(): Promise<void> {
        // Nothing is ever in flight here.
    }

    async awaitTask(_taskId: string): Promise<ITaskResult | undefined> {
        return undefined;
    }

    onTaskComplete(_callback: TaskCompletionCallback): UnsubscribeFn {
        return () => { /* nothing subscribed. */ };
    }

    onTaskMessage(_messageType: string, _callback: TaskMessageCallback): UnsubscribeFn {
        return () => { /* nothing subscribed. */ };
    }

    onAnyTaskMessage(_callback: TaskMessageCallback): UnsubscribeFn {
        return () => { /* nothing subscribed. */ };
    }

    shutdown(): void {
        // Nothing to shut down.
    }
}

describe("loadAssets", () => {

    test("queues the load as interactive, because the user is waiting on an empty gallery", () => {
        const queue = new RecordingTaskQueue();

        loadAssets(queue, "/photos/db", "load-1");

        expect(queue.addedTasks).toHaveLength(1);
        expect(queue.addedTasks[0].priority).toBe(TaskPriority.Interactive);
    });

    test("queues a load-assets task naming the database", () => {
        const queue = new RecordingTaskQueue();

        loadAssets(queue, "/photos/db", "load-1");

        expect(queue.addedTasks[0].type).toBe("load-assets");
        expect(queue.addedTasks[0].data).toEqual({
            databasePath: "/photos/db",
            job: {
                id: "load:/photos/db",
                name: "Loading assets",
                cancelSource: "load-1",
            },
        });
    });

    // The load is tagged with the id of that one load, never with the database path. cancelTasks()
    // takes a source and a cancelled load stops paging and reports success with no assets, so a load
    // tagged with the path is killed by every cancel of that path: the load it replaced and the load
    // that replaced it both reported 0 assets and the gallery stayed empty (smoke test 26).
    test("cancels by the id of the one load, which is the source its caller's queue is tagged with", () => {
        const queue = new RecordingTaskQueue();

        loadAssets(queue, "/photos/db", "load-1");

        expect(queue.addedTasks[0].data.job.cancelSource).toBe("load-1");
        expect(queue.addedTasks[0].data.job.cancelSource).not.toBe("/photos/db");
    });

    test("a second load of the same database is queued under its own id, so cancelling one leaves the other running", () => {
        const firstQueue = new RecordingTaskQueue();
        const secondQueue = new RecordingTaskQueue();

        loadAssets(firstQueue, "/photos/db", "load-1");
        loadAssets(secondQueue, "/photos/db", "load-2");

        expect(firstQueue.addedTasks[0].data.job.cancelSource).toBe("load-1");
        expect(secondQueue.addedTasks[0].data.job.cancelSource).toBe("load-2");
    });
});
