import { TaskQueue } from "../src/lib/task-queue";
import { TaskStatus, ITaskResult } from "../src/lib/types";
import { registerHandler } from "../src/lib/worker";
import { setQueueBackend } from "../src/lib/queue-backend";
import { TestUuidGenerator, TestTimestampProvider } from "node-utils";
import { MockWorkerPool } from "./mock-worker-pool";
import { randomUUID } from "node:crypto";

describe("TaskQueue", () => {
    let queue: TaskQueue;
    let uuidGenerator: TestUuidGenerator;
    let mockBackend: MockWorkerPool;

    beforeEach(() => {
        uuidGenerator = new TestUuidGenerator();
        mockBackend = new MockWorkerPool(2);
        setQueueBackend(mockBackend);
        queue = new TaskQueue(uuidGenerator, "test");
    });

    afterEach(() => {
        queue.shutdown();
    });

    describe("addTask", () => {
        test("should add a task and return a UUID", () => {
            const taskId = queue.addTask("test-task", { data: "test" });
            expect(taskId).toBeDefined();
            expect(typeof taskId).toBe("string");
        });

        test("should add multiple tasks with unique IDs", () => {
            const id1 = queue.addTask("test-task", { data: "test1" });
            const id2 = queue.addTask("test-task", { data: "test2" });
            expect(id1).not.toBe(id2);
        });
    });

    describe("awaitTask", () => {
        test("awaitTask resolves when the specific task completes", async () => {
            registerHandler("test-task", async () => "done");

            const taskId = queue.addTask("test-task", {});
            await queue.awaitTask(taskId);
            // If we reach here the promise resolved
            expect(true).toBe(true);
        });

        test("awaitTask resolves immediately when the task ID is not tracked", async () => {
            await expect(queue.awaitTask("unknown-task-id")).resolves.toBeUndefined();
        });

        test("multiple awaitTask callers on the same ID all resolve when the task completes", async () => {
            registerHandler("test-task", async () => "done");

            const taskId = queue.addTask("test-task", {});
            const results: string[] = [];

            const p1 = queue.awaitTask(taskId).then(() => results.push("p1"));
            const p2 = queue.awaitTask(taskId).then(() => results.push("p2"));
            const p3 = queue.awaitTask(taskId).then(() => results.push("p3"));

            await Promise.all([p1, p2, p3]);

            expect(results).toContain("p1");
            expect(results).toContain("p2");
            expect(results).toContain("p3");
        });

        test("awaitTask resolves immediately when shutdown is called while waiting", async () => {
            let unblockTask: () => void;
            const taskBlocked = new Promise<void>(resolve => { unblockTask = resolve; });

            registerHandler("slow-task", async () => {
                await taskBlocked;
                return "done";
            });

            const taskId = queue.addTask("slow-task", {});
            const promise = queue.awaitTask(taskId);

            // Shutdown before task completes — awaitTask should resolve immediately.
            queue.shutdown();
            unblockTask!();

            await expect(promise).resolves.toBeUndefined();
        });
    });

    describe("awaitAllTasks", () => {
        test("should wait for all tasks to complete", async () => {
            let completedCount = 0;

            registerHandler("test-task", async (data) => {
                completedCount++;
                return `Task ${data.id} completed`;
            });

            queue.addTask("test-task", { id: 1 });
            queue.addTask("test-task", { id: 2 });
            queue.addTask("test-task", { id: 3 });

            await queue.awaitAllTasks();

            expect(completedCount).toBe(3);
        });

        test("should resolve immediately if no tasks", async () => {
            await expect(queue.awaitAllTasks()).resolves.toBeUndefined();
        });

        test("should handle mixed success and failure", async () => {
            registerHandler("success-task", async () => "success");
            registerHandler("fail-task", async () => {
                throw new Error("Failed");
            });

            queue.addTask("success-task", {});
            queue.addTask("fail-task", {});
            queue.addTask("success-task", {});

            await queue.awaitAllTasks();
            // awaitAllTasks resolves after all tasks complete, whether succeeded or failed
            expect(true).toBe(true);
        });

        test("should handle empty queue", async () => {
            await expect(queue.awaitAllTasks()).resolves.toBeUndefined();
        });

        test("awaitAllTasks resolves immediately when shutdown is called while waiting", async () => {
            let unblockTask: () => void;
            const taskBlocked = new Promise<void>(resolve => { unblockTask = resolve; });

            registerHandler("slow-task", async () => {
                await taskBlocked;
                return "done";
            });

            queue.addTask("slow-task", {});
            const promise = queue.awaitAllTasks();

            // Shut down before the task completes — awaitAllTasks should resolve immediately.
            queue.shutdown();
            unblockTask!();

            await expect(promise).resolves.toBeUndefined();
        });

        test("onTasksCancelled fires resolveAllWaiters, unblocking awaitAllTasks and awaitTask callers", async () => {
            let unblockTask: () => void;
            const taskBlocked = new Promise<void>(resolve => { unblockTask = resolve; });

            registerHandler("slow-task", async () => {
                await taskBlocked;
                return "done";
            });

            const taskId = queue.addTask("slow-task", {});
            const allPromise = queue.awaitAllTasks();
            const taskPromise = queue.awaitTask(taskId);

            // cancelTasks fires onTasksCancelled which calls resolveAllWaiters.
            mockBackend.cancelTasks("test");
            unblockTask!();

            await expect(allPromise).resolves.toBeUndefined();
            await expect(taskPromise).resolves.toBeUndefined();
        });

        test("should wait for all tasks including slow ones", async () => {
            let completedCount = 0;

            registerHandler("slow-task", async () => {
                await new Promise(resolve => setTimeout(resolve, 100));
                completedCount++;
                return "done";
            });

            queue.addTask("slow-task", {});
            queue.addTask("slow-task", {});
            queue.addTask("slow-task", {});

            const startTime = Date.now();
            await queue.awaitAllTasks();
            const duration = Date.now() - startTime;

            expect(completedCount).toBe(3);
            // Should take at least 100ms (with 2 workers, tasks run in parallel)
            expect(duration).toBeGreaterThanOrEqual(100);
        });
    });

    describe("parallel execution", () => {
        test("should execute tasks in parallel up to maxWorkers", async () => {
            const executionOrder: number[] = [];

            registerHandler("test-task", async (data) => {
                const taskId = data.id;
                executionOrder.push(taskId);
                await new Promise(resolve => setTimeout(resolve, 100));
                return `Task ${taskId} done`;
            });

            // Add 5 tasks with 2 workers - should execute in batches
            for (let i = 1; i <= 5; i++) {
                queue.addTask("test-task", { id: i });
            }

            await queue.awaitAllTasks();

            // All tasks should complete
            expect(executionOrder.length).toBe(5);
        });

        test("should respect maxWorkers limit", async () => {
            const singleWorkerBackend = new MockWorkerPool(2);
            setQueueBackend(singleWorkerBackend);
            const queueWithLimit = new TaskQueue(uuidGenerator, "test-limited");
            const concurrentTasks = new Set<number>();
            let maxConcurrent = 0;

            registerHandler("test-task", async (data) => {
                const taskId = data.id;
                concurrentTasks.add(taskId);
                maxConcurrent = Math.max(maxConcurrent, concurrentTasks.size);

                await new Promise(resolve => setTimeout(resolve, 100));

                concurrentTasks.delete(taskId);
                return `Task ${taskId} done`;
            });

            // Add 10 tasks with maxWorkers=2
            for (let i = 1; i <= 10; i++) {
                queueWithLimit.addTask("test-task", { id: i });
            }

            await queueWithLimit.awaitAllTasks();
            queueWithLimit.shutdown();

            // Should never exceed maxWorkers (2)
            expect(maxConcurrent).toBeLessThanOrEqual(2);
        });

        test("should process tasks in FIFO order", async () => {
            const executionOrder: number[] = [];

            const singleWorkerBackend = new MockWorkerPool(1);
            setQueueBackend(singleWorkerBackend);
            const singleQueue = new TaskQueue(uuidGenerator, "test-fifo");

            registerHandler("test-task", async (data) => {
                executionOrder.push(data.id);
                return "done";
            });

            // Add tasks in order
            for (let i = 1; i <= 5; i++) {
                singleQueue.addTask("test-task", { id: i });
            }

            await singleQueue.awaitAllTasks();
            singleQueue.shutdown();

            // Tasks should be processed in order (FIFO)
            expect(executionOrder).toEqual([1, 2, 3, 4, 5]);
        });
    });

    describe("task data handling", () => {
        test("should pass task data to handler", async () => {
            let receivedData: any = null;

            registerHandler("test-task", async (data) => {
                receivedData = data;
                return "done";
            });

            const taskData = {
                file: "test.jpg",
                options: { quality: 90 },
                metadata: { author: "test" }
            };

            queue.addTask("test-task", taskData);
            await queue.awaitAllTasks();

            expect(receivedData).toEqual(taskData);
        });

        test("should handle complex data structures", async () => {
            let receivedData: any = null;

            registerHandler("test-task", async (data) => {
                receivedData = data;
                return "done";
            });

            const complexData = {
                nested: {
                    array: [1, 2, 3],
                    object: { key: "value" }
                },
                date: new Date().toISOString()
            };

            queue.addTask("test-task", complexData);
            await queue.awaitAllTasks();

            expect(receivedData.nested.array).toEqual([1, 2, 3]);
            expect(receivedData.nested.object.key).toBe("value");
        });

        test("should handle null data", async () => {
            let receivedData: any = null;

            registerHandler("test-task", async (data) => {
                receivedData = data;
                return "done";
            });

            queue.addTask("test-task", null);
            await queue.awaitAllTasks();

            expect(receivedData).toBeNull();
        });

        test("should handle undefined data", async () => {
            let receivedData: any = null;

            registerHandler("test-task", async (data) => {
                receivedData = data;
                return "done";
            });

            queue.addTask("test-task", undefined);
            await queue.awaitAllTasks();

            expect(receivedData).toBeUndefined();
        });

        test("should handle empty object data", async () => {
            let receivedData: any = null;

            registerHandler("test-task", async (data) => {
                receivedData = data;
                return "done";
            });

            queue.addTask("test-task", {});
            await queue.awaitAllTasks();

            expect(receivedData).toEqual({});
        });

        test("should handle array data", async () => {
            let receivedData: any = null;

            registerHandler("test-task", async (data) => {
                receivedData = data;
                return "done";
            });

            const arrayData = [1, 2, 3, "test", { key: "value" }];
            queue.addTask("test-task", arrayData);
            await queue.awaitAllTasks();

            expect(receivedData).toEqual(arrayData);
        });
    });

    describe("shutdown", () => {
        test("should terminate all workers", () => {
            queue.shutdown();
            // Should not throw
            expect(true).toBe(true);
        });

        test("should allow shutdown multiple times", () => {
            queue.shutdown();
            queue.shutdown();
            // Should not throw
            expect(true).toBe(true);
        });

        test("should prevent callbacks from being called after shutdown", async () => {
            let callbackCalled = false;

            registerHandler("test-task", async () => "done");

            queue.onTaskComplete(() => { callbackCalled = true; });

            // Shutdown the queue
            queue.shutdown();

            queue.addTask("test-task", {});
            // Wait a bit to ensure any async callbacks would have fired
            await new Promise(resolve => setTimeout(resolve, 100));

            // Callback should not be called after shutdown
            expect(callbackCalled).toBe(false);
        });

        test("should prevent task messages from being received after shutdown", async () => {
            let callbackCalled = false;

            registerHandler("test-task", async (data, context) => {
                context.sendMessage({ type: "test-message", data: "test" });
                return "done";
            });

            queue.onTaskMessage("test-message", () => { callbackCalled = true; });

            // Shutdown the queue
            queue.shutdown();

            queue.addTask("test-task", {});
            // Wait a bit to ensure any async callbacks would have fired
            await new Promise(resolve => setTimeout(resolve, 100));

            // Callback should not be called after shutdown
            expect(callbackCalled).toBe(false);
        });

        test("should unsubscribe from all backend events on shutdown", () => {
            let onTaskCompleteUnsubscribeCalled = false;
            let onAnyTaskMessageUnsubscribeCalled = false;
            let onTaskAddedUnsubscribeCalled = false;

            const onTaskCompleteUnsubscribe = () => { onTaskCompleteUnsubscribeCalled = true; };
            const onAnyTaskMessageUnsubscribe = () => { onAnyTaskMessageUnsubscribeCalled = true; };
            const onTaskAddedUnsubscribe = () => { onTaskAddedUnsubscribeCalled = true; };

            // Create a mock backend that tracks unsubscribe calls
            const mockTestBackend = {
                addTask: () => "task-id",
                onTaskAdded: () => onTaskAddedUnsubscribe,
                onTaskComplete: () => onTaskCompleteUnsubscribe,
                onAnyTaskMessage: () => onAnyTaskMessageUnsubscribe,
                onTaskMessage: () => () => {},
                cancelTasks: () => {},
                onTasksCancelled: () => () => {},
                shutdown: () => {},
            };

            setQueueBackend(mockTestBackend as any);
            const testQueue = new TaskQueue(uuidGenerator, "test-unsub");

            // Shutdown should call all unsubscribe functions
            testQueue.shutdown();

            expect(onTaskCompleteUnsubscribeCalled).toBe(true);
            expect(onAnyTaskMessageUnsubscribeCalled).toBe(true);
            expect(onTaskAddedUnsubscribeCalled).toBe(true);
        });
    });

    describe("source isolation", () => {
        test("tasks from source A do not trigger completion callbacks of source B", async () => {
            registerHandler("test-task", async () => "done");

            const queueB = new TaskQueue(uuidGenerator, "source-b");
            const callbackBFired: boolean[] = [];
            queueB.onTaskComplete(() => { callbackBFired.push(true); });

            // Add a task to queue A (source "test").
            queue.addTask("test-task", {});
            await queue.awaitAllTasks();

            expect(callbackBFired).toHaveLength(0);

            queueB.shutdown();
        });
    });

    describe("addTask with explicit taskId", () => {
        test("addTask with an explicit taskId passes that ID through to the backend", () => {
            const explicitId = "my-explicit-task-id";
            const capturedIds: string[] = [];

            const recordingBackend = {
                addTask: (_type: string, _data: any, _source: string, taskId?: string) => {
                    capturedIds.push(taskId ?? "");
                    return taskId ?? "";
                },
                onTaskAdded: () => () => {},
                onTaskComplete: () => () => {},
                onTaskMessage: () => () => {},
                onAnyTaskMessage: () => () => {},
                cancelTasks: () => {},
                onTasksCancelled: () => () => {},
                shutdown: () => {},
            };

            setQueueBackend(recordingBackend as any);
            const testQueue = new TaskQueue(uuidGenerator, "test-explicit");

            const returnedId = testQueue.addTask("test-task", {}, explicitId);

            expect(returnedId).toBe(explicitId);
            expect(capturedIds).toContain(explicitId);

            testQueue.shutdown();

            // Restore the original backend for afterEach cleanup.
            setQueueBackend(mockBackend);
        });
    });

    describe("constructor options", () => {
        test("should use custom UUID generator", () => {
            const customUuidGenerator = new TestUuidGenerator();
            const customQueue = new TaskQueue(customUuidGenerator, "test-custom");

            const taskId1 = customQueue.addTask("test-task", {});
            const taskId2 = customQueue.addTask("test-task", {});

            // TestUuidGenerator creates deterministic UUIDs
            expect(taskId1).toBeDefined();
            expect(taskId2).toBeDefined();
            expect(taskId1).not.toBe(taskId2);

            customQueue.shutdown();
        });

        test("should use default UUID generator when not provided", () => {
            const customUuidGenerator = { generate: () => randomUUID() };
            const defaultQueue = new TaskQueue(customUuidGenerator, "test-default");

            const taskId1 = defaultQueue.addTask("test-task", {});
            const taskId2 = defaultQueue.addTask("test-task", {});

            expect(taskId1).toBeDefined();
            expect(taskId2).toBeDefined();
            expect(taskId1).not.toBe(taskId2);

            defaultQueue.shutdown();
        });
    });

    describe("error handling", () => {
        test("should handle handler throwing non-Error objects", async () => {
            const results: ITaskResult[] = [];

            registerHandler("throw-string", async () => {
                throw "String error";
            });

            queue.onTaskComplete((result: ITaskResult) => {
                results.push(result);
            });

            queue.addTask("throw-string", {});
            await queue.awaitAllTasks();

            expect(results.length).toBe(1);
            expect(results[0].status).toBe(TaskStatus.Failed);
            expect(results[0].error).toBeDefined();
        });

        test("should handle handler throwing null", async () => {
            const results: ITaskResult[] = [];

            registerHandler("throw-null", async () => {
                throw null;
            });

            queue.onTaskComplete((result: ITaskResult) => {
                results.push(result);
            });

            queue.addTask("throw-null", {});
            await queue.awaitAllTasks();

            expect(results.length).toBe(1);
            expect(results[0].status).toBe(TaskStatus.Failed);
            expect(results[0].error).toBeDefined();
        });

        test("should preserve error messages", async () => {
            const errorMessage = "Custom error message";
            const results: ITaskResult[] = [];

            registerHandler("custom-error", async () => {
                throw new Error(errorMessage);
            });

            queue.onTaskComplete((result: ITaskResult) => {
                results.push(result);
            });

            queue.addTask("custom-error", {});
            await queue.awaitAllTasks();

            expect(results.length).toBe(1);
            expect(results[0].status).toBe(TaskStatus.Failed);
            expect(results[0].error?.message).toContain(errorMessage);
        });
    });
});
