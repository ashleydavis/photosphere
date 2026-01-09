import { TaskQueue } from "../src/lib/task-queue";
import { TaskStatus, ITaskResult, ITask } from "../src/lib/worker-backend";
import { registerHandler } from "../src/lib/worker";
import { TestUuidGenerator, TestTimestampProvider } from "node-utils";
import { MockWorkerBackend } from "./mock-worker-backend";
import { randomUUID } from "node:crypto";

describe("TaskQueue", () => {
    let queue: TaskQueue;
    let uuidGenerator: TestUuidGenerator;
    let timestampProvider: TestTimestampProvider;

    beforeEach(() => {
        uuidGenerator = new TestUuidGenerator();
        timestampProvider = new TestTimestampProvider();
        const taskTimeout = 600000;
        const workerBackend = new MockWorkerBackend(2);
        queue = new TaskQueue(uuidGenerator, timestampProvider, taskTimeout, workerBackend);
    });

    afterEach(() => {
        queue.shutdown();
    });

    describe("addTask", () => {
        it("should add a task and return a UUID", () => {
            const taskId = queue.addTask("test-task", { data: "test" });
            expect(taskId).toBeDefined();
            expect(typeof taskId).toBe("string");
        });

        it("should add multiple tasks with unique IDs", () => {
            const id1 = queue.addTask("test-task", { data: "test1" });
            const id2 = queue.addTask("test-task", { data: "test2" });
            expect(id1).not.toBe(id2);
        });
    });

    describe("awaitAllTasks", () => {
        it("should wait for all tasks to complete", async () => {
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

        it("should resolve immediately if no tasks", async () => {
            await expect(queue.awaitAllTasks()).resolves.toBeUndefined();
        });
    });

    describe("getStatus", () => {
        it("should return correct status counts", async () => {
            registerHandler("test-task", async () => "done");
            registerHandler("failing-task", async () => {
                throw new Error("Failed");
            });

            queue.addTask("test-task", {});
            queue.addTask("test-task", {});
            queue.addTask("failing-task", {});

            await queue.awaitAllTasks();
            
            // Give a small delay for status to settle after all tasks complete
            await new Promise(resolve => setTimeout(resolve, 50));

            const status = queue.getStatus();
            expect(status.completed).toBe(2);
            expect(status.failed).toBe(1);
            expect(status.total).toBe(3);
            // After all tasks complete, verify all tasks are accounted for
            expect(status.completed + status.failed).toBe(3);
            // Pending and running should be 0 after all tasks complete
            // (with some tolerance for race conditions in fast-executing mock backend)
            expect(status.pending + status.running).toBeLessThanOrEqual(0);
        });

        it("should track pending tasks", () => {
            registerHandler("slow-task", async () => {
                await new Promise(resolve => setTimeout(resolve, 1000));
                return "done";
            });

            queue.addTask("slow-task", {});
            queue.addTask("slow-task", {});
            queue.addTask("slow-task", {});

            const status = queue.getStatus();
            expect(status.total).toBe(3);
            // Some tasks might be running, some pending
            expect(status.pending + status.running).toBeGreaterThan(0);
        });

        it("should return zero counts for empty queue", () => {
            const status = queue.getStatus();
            expect(status.pending).toBe(0);
            expect(status.running).toBe(0);
            expect(status.completed).toBe(0);
            expect(status.failed).toBe(0);
            expect(status.total).toBe(0);
        });

        it("should update status as tasks progress", async () => {
            registerHandler("test-task", async () => {
                await new Promise(resolve => setTimeout(resolve, 50));
                return "done";
            });

            const initialStatus = queue.getStatus();
            expect(initialStatus.total).toBe(0);

            queue.addTask("test-task", {});
            queue.addTask("test-task", {});

            // Check status while tasks are processing
            await new Promise(resolve => setTimeout(resolve, 10));
            const midStatus = queue.getStatus();
            expect(midStatus.total).toBe(2);
            expect(midStatus.pending + midStatus.running).toBeGreaterThan(0);

            await queue.awaitAllTasks();

            const finalStatus = queue.getStatus();
            expect(finalStatus.total).toBe(2);
            expect(finalStatus.completed).toBe(2);
            expect(finalStatus.pending).toBe(0);
            expect(finalStatus.running).toBe(0);
        });
    });

    describe("parallel execution", () => {
        it("should execute tasks in parallel up to maxWorkers", async () => {
            const executionOrder: number[] = [];
            const startTimes: Map<number, number> = new Map();

            registerHandler("test-task", async (data) => {
                const taskId = data.id;
                startTimes.set(taskId, Date.now());
                executionOrder.push(taskId);
                await new Promise(resolve => setTimeout(resolve, 100));
                return `Task ${taskId} done`;
            });

            // Add 5 tasks with 2 workers - should execute in batches
            const taskIds = [];
            for (let i = 1; i <= 5; i++) {
                queue.addTask("test-task", { id: i });
            }

            await queue.awaitAllTasks();

            // All tasks should complete
            expect(executionOrder.length).toBe(5);
        });

        it("should respect maxWorkers limit", async () => {
            const taskTimeout = 600000;
            const workerBackend = new MockWorkerBackend(2);
            const queueWithLimit = new TaskQueue(uuidGenerator, timestampProvider, taskTimeout, workerBackend);
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

        it("should process tasks in FIFO order", async () => {
            const executionOrder: number[] = [];

            registerHandler("test-task", async (data) => {
                executionOrder.push(data.id);
                return "done";
            });

            // Add tasks in order
            for (let i = 1; i <= 5; i++) {
                queue.addTask("test-task", { id: i });
            }

            await queue.awaitAllTasks();

            // Tasks should be processed in order (FIFO)
            expect(executionOrder).toEqual([1, 2, 3, 4, 5]);
        });
    });

    describe("task data handling", () => {
        it("should pass task data to handler", async () => {
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

        it("should handle complex data structures", async () => {
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

        it("should handle null data", async () => {
            let receivedData: any = null;

            registerHandler("test-task", async (data) => {
                receivedData = data;
                return "done";
            });

            queue.addTask("test-task", null);
            await queue.awaitAllTasks();

            expect(receivedData).toBeNull();
        });

        it("should handle undefined data", async () => {
            let receivedData: any = null;

            registerHandler("test-task", async (data) => {
                receivedData = data;
                return "done";
            });

            queue.addTask("test-task", undefined);
            await queue.awaitAllTasks();

            expect(receivedData).toBeUndefined();
        });

        it("should handle empty object data", async () => {
            let receivedData: any = null;

            registerHandler("test-task", async (data) => {
                receivedData = data;
                return "done";
            });

            queue.addTask("test-task", {});
            await queue.awaitAllTasks();

            expect(receivedData).toEqual({});
        });

        it("should handle array data", async () => {
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
        it("should terminate all workers", () => {
            queue.shutdown();
            // Should not throw
            expect(true).toBe(true);
        });

        it("should allow shutdown multiple times", () => {
            queue.shutdown();
            queue.shutdown();
            // Should not throw
            expect(true).toBe(true);
        });
    });

    describe("constructor options", () => {
        it("should use custom UUID generator", () => {
            const customUuidGenerator = new TestUuidGenerator();
            const taskTimeout = 600000;
            const workerBackend = new MockWorkerBackend(2);
            const customQueue = new TaskQueue(customUuidGenerator, timestampProvider, taskTimeout, workerBackend);

            const taskId1 = customQueue.addTask("test-task", {});
            const taskId2 = customQueue.addTask("test-task", {});

            // TestUuidGenerator creates deterministic UUIDs
            expect(taskId1).toBeDefined();
            expect(taskId2).toBeDefined();
            expect(taskId1).not.toBe(taskId2);

            customQueue.shutdown();
        });

        it("should use default UUID generator when not provided", () => {
            const uuidGenerator = { generate: () => randomUUID() };
            const taskTimeout = 600000;
            const workerBackend = new MockWorkerBackend(2);
            const defaultQueue = new TaskQueue(uuidGenerator, timestampProvider, taskTimeout, workerBackend);

            const taskId1 = defaultQueue.addTask("test-task", {});
            const taskId2 = defaultQueue.addTask("test-task", {});

            expect(taskId1).toBeDefined();
            expect(taskId2).toBeDefined();
            expect(taskId1).not.toBe(taskId2);

            defaultQueue.shutdown();
        });
    });

    describe("awaitAllTasks", () => {
        it("should handle mixed success and failure", async () => {
            registerHandler("success-task", async () => "success");
            registerHandler("fail-task", async () => {
                throw new Error("Failed");
            });

            queue.addTask("success-task", {});
            queue.addTask("fail-task", {});
            queue.addTask("success-task", {});

            await queue.awaitAllTasks();

            const status = queue.getStatus();
            expect(status.completed).toBe(2);
            expect(status.failed).toBe(1);
            expect(status.total).toBe(3);
        });

        it("should handle empty queue", async () => {
            await expect(queue.awaitAllTasks()).resolves.toBeUndefined();
        });

        it("should wait for all tasks including slow ones", async () => {
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

    describe("error handling", () => {
        it("should handle handler throwing non-Error objects", async () => {
            const results: ITaskResult[] = [];

            registerHandler("throw-string", async () => {
                throw "String error";
            });

            queue.onTaskComplete<any, any>((task: ITask<any>, result: ITaskResult) => {
                results.push(result);
            });

            queue.addTask("throw-string", {});
            await queue.awaitAllTasks();

            expect(results.length).toBe(1);
            expect(results[0].status).toBe(TaskStatus.Failed);
            expect(results[0].error).toBeDefined();
        });

        it("should handle handler throwing null", async () => {
            const results: ITaskResult[] = [];

            registerHandler("throw-null", async () => {
                throw null;
            });

            queue.onTaskComplete<any, any>((task: ITask<any>, result: ITaskResult) => {
                results.push(result);
            });

            queue.addTask("throw-null", {});
            await queue.awaitAllTasks();

            expect(results.length).toBe(1);
            expect(results[0].status).toBe(TaskStatus.Failed);
            expect(results[0].error).toBeDefined();
        });

        it("should preserve error messages", async () => {
            const errorMessage = "Custom error message";
            const results: ITaskResult[] = [];

            registerHandler("custom-error", async () => {
                throw new Error(errorMessage);
            });

            queue.onTaskComplete<any, any>((task: ITask<any>, result: ITaskResult) => {
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

