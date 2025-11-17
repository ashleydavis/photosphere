import { randomUUID } from "node:crypto";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { IUuidGenerator } from "utils";
import { registerHandler as registerHandlerInRegistry, getHandler } from "./handler-registry";

//
// Task status enumeration
//
export enum TaskStatus {
    Pending = "pending",
    Running = "running",
    Completed = "completed",
    Failed = "failed"
}

//
// Task result interface
//
export interface ITaskResult {
    status: TaskStatus;
    message?: string;
    error?: string;
    outputs?: any; // The actual result data returned by the handler
    inputs: any; // The original arguments/data sent to the task
    taskId: string;
    taskType: string;
    createdAt: Date;
    startedAt?: Date;
    completedAt?: Date;
}

//
// Task data structure
//
interface ITask {
    id: string;
    type: string;
    status: TaskStatus;
    data: any;
    result?: ITaskResult;
    workingDirectory: string;
    createdAt: Date;
    startedAt?: Date;
    completedAt?: Date;
}

//
// Task handler function type
// Returns the result payload (can be any type)
//
export type TaskHandler = (data: any, workingDirectory: string) => Promise<any>;

//
// Task completion callback
//
export type TaskCompletionCallback = (result: ITaskResult) => void;

//
// Queue status interface
//
export interface IQueueStatus {
    pending: number;
    running: number;
    completed: number;
    failed: number;
    total: number;
}

//
// Task queue interface
//
export interface ITaskQueue {
    //
    // Adds a task to the queue to be run. Returns uuid of the task.
    //
    addTask(type: string, data: any): string;

    //
    // Registers a task handler that can do some work for a named type of task
    // (e.g. "upload-image") then return a result payload.
    //
    registerHandler(type: string, handler: TaskHandler): void;

    //
    // Registers a callback that will be called when any task completes (success or failure).
    //
    onTaskComplete(callback: TaskCompletionCallback): void;

    //
    // Awaits the completion of a particular task.
    //
    awaitTask(id: string): Promise<ITaskResult>;

    //
    // Retrieves the status of a particular task.
    //
    taskStatus(id: string): ITaskResult | undefined;

    //
    // Gets the full result of a particular task (including payload).
    //
    getTaskResult(id: string): ITaskResult | undefined;

    //
    // Gets results for all tasks.
    //
    getAllTaskResults(): ITaskResult[];

    //
    // Gets results for all successful tasks.
    //
    getSuccessfulTaskResults(): ITaskResult[];

    //
    // Gets results for all failed tasks.
    //
    getFailedTaskResults(): ITaskResult[];

    //
    // Awaits the completion of all tasks and an empty queue.
    //
    awaitAllTasks(): Promise<void>;

    //
    // Gets the status of the queue: number of pending tasks, successful tasks, failed tasks, etc.
    //
    getStatus(): IQueueStatus;
}

//
// Task queue implementation using Bun workers
//
export class TaskQueue implements ITaskQueue {
    private tasks: Map<string, ITask> = new Map();
    private handlers: Map<string, TaskHandler> = new Map();
    private pendingTasks: string[] = [];
    private runningTasks: Set<string> = new Set();
    private maxWorkers: number;
    private baseWorkingDirectory: string;
    private uuidGenerator: IUuidGenerator;
    private taskResolvers: Map<string, { resolve: (result: ITaskResult) => void; reject: (error: Error) => void }> = new Map();
    private allTasksResolver: { resolve: () => void; reject: (error: Error) => void } | null = null;
    private completionCallbacks: TaskCompletionCallback[] = [];

    //
    // Creates a new task queue with the specified number of workers.
    // Tasks will execute with concurrency limited by maxWorkers.
    //
    constructor(maxWorkers: number = 4, baseWorkingDirectory?: string, uuidGenerator?: IUuidGenerator) {
        this.maxWorkers = maxWorkers;
        this.baseWorkingDirectory = baseWorkingDirectory || join(tmpdir(), "task-queue");
        this.uuidGenerator = uuidGenerator || {
            generate: () => randomUUID()
        } as IUuidGenerator;

        // Create worker pool
        // Note: Workers are created but not actively used yet
        // They're reserved for future CPU-intensive task execution
        // For now, tasks execute in the main thread with concurrency control
        for (let i = 0; i < maxWorkers; i++) {
            // Workers will be used in the future for isolated task execution
            // For now, we just track the worker count for concurrency control
        }
    }

    //
    // Adds a task to the queue to be executed. Returns the task ID (UUID).
    // The task will be executed when a worker becomes available.
    //
    addTask(type: string, data: any): string {
        const id = this.uuidGenerator.generate();
        const workingDirectory = join(this.baseWorkingDirectory, id);

        const task: ITask = {
            id,
            type,
            status: TaskStatus.Pending,
            data,
            workingDirectory,
            createdAt: new Date()
        };

        this.tasks.set(id, task);
        this.pendingTasks.push(id);
        this.processNextTask();

        return id;
    }

    //
    // Registers a handler function for a specific task type.
    // The handler will be called to process tasks of this type.
    //
    registerHandler(type: string, handler: TaskHandler): void {
        this.handlers.set(type, handler);
        // Also register in global registry for workers
        registerHandlerInRegistry(type, handler);
    }

    //
    // Registers a callback that will be invoked whenever any task completes (success or failure).
    // Multiple callbacks can be registered and will all be called.
    //
    onTaskComplete(callback: TaskCompletionCallback): void {
        this.completionCallbacks.push(callback);
    }

    //
    // Waits for a specific task to complete and returns its result.
    // If the task is already complete, returns immediately.
    // Throws an error if the task ID is not found.
    //
    async awaitTask(id: string): Promise<ITaskResult> {
        const task = this.tasks.get(id);
        if (!task) {
            throw new Error(`Task ${id} not found`);
        }

        if (task.status === TaskStatus.Completed || task.status === TaskStatus.Failed) {
            return {
                status: task.status,
                message: task.result?.message,
                error: task.result?.error,
                outputs: task.result?.outputs,
                inputs: task.data,
                taskId: task.id,
                taskType: task.type,
                createdAt: task.createdAt,
                startedAt: task.startedAt,
                completedAt: task.completedAt
            };
        }

        return new Promise<ITaskResult>((resolve, reject) => {
            this.taskResolvers.set(id, { resolve, reject });
        });
    }

    //
    // Gets the current status and result of a task without waiting.
    // Returns undefined if the task ID is not found.
    //
    taskStatus(id: string): ITaskResult | undefined {
        const task = this.tasks.get(id);
        if (!task) {
            return undefined;
        }

        return {
            status: task.status,
            message: task.result?.message,
            error: task.result?.error,
            outputs: task.result?.outputs,
            inputs: task.data,
            taskId: task.id,
            taskType: task.type,
            createdAt: task.createdAt,
            startedAt: task.startedAt,
            completedAt: task.completedAt
        };
    }

    //
    // Gets the full result of a specific task (same as taskStatus but more explicit).
    // Returns undefined if the task ID is not found.
    //
    getTaskResult(id: string): ITaskResult | undefined {
        return this.taskStatus(id);
    }

    //
    // Returns results for all tasks (pending, running, completed, and failed).
    // Useful for getting a complete snapshot of all tasks in the queue.
    //
    getAllTaskResults(): ITaskResult[] {
        const results: ITaskResult[] = [];
        for (const task of this.tasks.values()) {
            results.push({
                status: task.status,
                message: task.result?.message,
                error: task.result?.error,
                outputs: task.result?.outputs,
                inputs: task.data,
                taskId: task.id,
                taskType: task.type,
                createdAt: task.createdAt,
                startedAt: task.startedAt,
                completedAt: task.completedAt
            });
        }
        return results;
    }

    //
    // Returns results for all successfully completed tasks.
    // Useful for processing only successful results.
    //
    getSuccessfulTaskResults(): ITaskResult[] {
        return this.getAllTaskResults().filter(result => result.status === TaskStatus.Completed);
    }

    //
    // Returns results for all failed tasks.
    // Useful for error handling and retry logic.
    //
    getFailedTaskResults(): ITaskResult[] {
        return this.getAllTaskResults().filter(result => result.status === TaskStatus.Failed);
    }

    //
    // Waits for all pending and running tasks to complete.
    // Resolves when the queue is empty (no pending or running tasks).
    //
    async awaitAllTasks(): Promise<void> {
        if (this.pendingTasks.length === 0 && this.runningTasks.size === 0) {
            return;
        }

        return new Promise<void>((resolve, reject) => {
            this.allTasksResolver = { resolve, reject };
            this.checkAllTasksComplete();
        });
    }

    //
    // Gets a summary of the queue status: counts of pending, running, completed, and failed tasks.
    // Useful for monitoring and progress tracking.
    //
    getStatus(): IQueueStatus {
        let pending = 0;
        let running = 0;
        let completed = 0;
        let failed = 0;

        for (const task of this.tasks.values()) {
            switch (task.status) {
                case TaskStatus.Pending:
                    pending++;
                    break;
                case TaskStatus.Running:
                    running++;
                    break;
                case TaskStatus.Completed:
                    completed++;
                    break;
                case TaskStatus.Failed:
                    failed++;
                    break;
            }
        }

        return {
            pending,
            running,
            completed,
            failed,
            total: this.tasks.size
        };
    }

    //
    // Internal: Processes the next pending task if a worker is available.
    // Called automatically when tasks are added or completed.
    //
    private processNextTask(): void {
        if (this.pendingTasks.length === 0) {
            this.checkAllTasksComplete();
            return;
        }

        // Find an available worker
        const availableWorkerIndex = this.findAvailableWorker();
        if (availableWorkerIndex === -1) {
            return; // All workers busy
        }

        const taskId = this.pendingTasks.shift()!;
        const task = this.tasks.get(taskId);
        if (!task) {
            return;
        }

        const handler = this.handlers.get(task.type);
        if (!handler) {
            // No handler registered, mark as failed
            task.status = TaskStatus.Failed;
            task.completedAt = new Date();
            const result: ITaskResult = {
                status: TaskStatus.Failed,
                error: `No handler registered for task type: ${task.type}`,
                inputs: task.data,
                taskId: task.id,
                taskType: task.type,
                createdAt: task.createdAt,
                startedAt: task.startedAt,
                completedAt: task.completedAt
            };
            task.result = result;
            this.notifyCompletionCallbacks(result);
            this.resolveTask(taskId, result);
            this.processNextTask();
            return;
        }

        // Mark task as running
        task.status = TaskStatus.Running;
        task.startedAt = new Date();
        this.runningTasks.add(taskId);

        // Execute handler with concurrency control
        // Note: Workers are created but handlers execute in main thread for now
        // Workers can be used for CPU-intensive tasks in the future
        this.executeTask(task, handler);
    }

    //
    // Internal: Finds an available worker slot for task execution.
    // Returns -1 if all workers are busy (concurrency limit reached).
    //
    private findAvailableWorker(): number {
        // Simple round-robin, but we could make this smarter
        // For now, we'll just check if we have capacity
        if (this.runningTasks.size >= this.maxWorkers) {
            return -1;
        }

        // Find the worker with the least tasks (simple approach)
        // In a real implementation, we might track per-worker task counts
        return this.runningTasks.size % this.maxWorkers;
    }

    //
    // Internal: Executes a task handler and handles success/failure.
    // Automatically catches errors, updates task status, and triggers callbacks.
    //
    private executeTask(task: ITask, handler: TaskHandler): void {
        // Execute handler asynchronously with concurrency limit
        (async () => {
            try {
                const outputs = await handler(task.data, task.workingDirectory);
                
                task.status = TaskStatus.Completed;
                task.completedAt = new Date();
                const result: ITaskResult = {
                    status: TaskStatus.Completed,
                    message: typeof outputs === "string" ? outputs : "Task completed successfully",
                    outputs: outputs,
                    inputs: task.data,
                    taskId: task.id,
                    taskType: task.type,
                    createdAt: task.createdAt,
                    startedAt: task.startedAt,
                    completedAt: task.completedAt
                };
                task.result = result;
                this.runningTasks.delete(task.id);

                this.notifyCompletionCallbacks(result);
                this.resolveTask(task.id, result);
                this.processNextTask();
            } catch (error: any) {
                task.status = TaskStatus.Failed;
                task.completedAt = new Date();
                const errorMessage = error?.message || (error !== null && error !== undefined ? String(error) : "Unknown error");
                const errorString = error ? JSON.stringify({
                    message: errorMessage,
                    stack: error?.stack,
                    name: error?.name,
                    ...(typeof error === "object" && error !== null ? error : {})
                }, null, 2) : "Unknown error";
                const result: ITaskResult = {
                    status: TaskStatus.Failed,
                    error: errorString,
                    inputs: task.data,
                    taskId: task.id,
                    taskType: task.type,
                    createdAt: task.createdAt,
                    startedAt: task.startedAt,
                    completedAt: task.completedAt
                };
                task.result = result;
                this.runningTasks.delete(task.id);

                this.notifyCompletionCallbacks(result);
                this.resolveTask(task.id, result);
                this.processNextTask();
            }
        })();
    }

    //
    // Internal: Invokes all registered completion callbacks with the task result.
    // Callback errors are caught and logged to prevent breaking the queue.
    //
    private notifyCompletionCallbacks(result: ITaskResult): void {
        for (const callback of this.completionCallbacks) {
            try {
                callback(result);
            } catch (error) {
                // Don't let callback errors break the task queue
                console.error("Error in task completion callback:", error);
            }
        }
    }

    //
    // Internal: Handles messages from worker threads (reserved for future use).
    // Currently tasks execute in the main thread, but this is prepared for worker-based execution.
    //
    private handleWorkerMessage(message: any): void {
        if (message.type === "result") {
            const { taskId, result } = message;
            const task = this.tasks.get(taskId);
            if (!task) {
                return;
            }

            task.status = result.status;
            task.completedAt = new Date();
            const fullResult: ITaskResult = {
                ...result,
                inputs: task.data,
                taskId: task.id,
                taskType: task.type,
                createdAt: task.createdAt,
                startedAt: task.startedAt,
                completedAt: task.completedAt
            };
            task.result = fullResult;
            this.runningTasks.delete(taskId);

            this.notifyCompletionCallbacks(fullResult);
            this.resolveTask(taskId, fullResult);
            this.processNextTask();
        } else if (message.type === "error") {
            const { taskId, error } = message;
            const task = this.tasks.get(taskId);
            if (!task) {
                return;
            }

            task.status = TaskStatus.Failed;
            task.completedAt = new Date();
            const errorString = error ? JSON.stringify({
                message: error.message || String(error),
                stack: error.stack,
                name: error.name,
                ...(typeof error === "object" && error !== null ? error : {})
            }, null, 2) : "Unknown error";
            const result: ITaskResult = {
                status: TaskStatus.Failed,
                error: errorString,
                inputs: task.data,
                taskId: task.id,
                taskType: task.type,
                createdAt: task.createdAt,
                startedAt: task.startedAt,
                completedAt: task.completedAt
            };
            task.result = result;
            this.runningTasks.delete(taskId);

            this.notifyCompletionCallbacks(result);
            this.resolveTask(taskId, result);
            this.processNextTask();
        }
    }

    //
    // Internal: Resolves any promises waiting for this task to complete.
    // Also checks if all tasks are complete to resolve awaitAllTasks().
    //
    private resolveTask(taskId: string, result: ITaskResult): void {
        const resolver = this.taskResolvers.get(taskId);
        if (resolver) {
            this.taskResolvers.delete(taskId);
            resolver.resolve(result);
        }

        this.checkAllTasksComplete();
    }

    //
    // Internal: Checks if all tasks are complete and resolves awaitAllTasks() if so.
    // Called after each task completes.
    //
    private checkAllTasksComplete(): void {
        if (this.allTasksResolver && this.pendingTasks.length === 0 && this.runningTasks.size === 0) {
            const resolver = this.allTasksResolver;
            this.allTasksResolver = null;
            resolver.resolve();
        }
    }

    //
    // Shuts down the task queue and cleans up resources.
    // Should be called when the queue is no longer needed.
    //
    shutdown(): void {
        // Workers will be terminated when actively used
        // For now, this is a no-op
    }
}

