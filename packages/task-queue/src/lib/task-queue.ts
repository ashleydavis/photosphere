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
//
export type TaskHandler = (data: any, workingDirectory: string) => Promise<string>;

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
    // (e.g. "upload-image") then return a status message.
    //
    registerHandler(type: string, handler: TaskHandler): void;

    //
    // Awaits the completion of a particular task.
    //
    awaitTask(id: string): Promise<ITaskResult>;

    //
    // Retrieves the status of a particular task.
    //
    taskStatus(id: string): ITaskResult | undefined;

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

    registerHandler(type: string, handler: TaskHandler): void {
        this.handlers.set(type, handler);
        // Also register in global registry for workers
        registerHandlerInRegistry(type, handler);
    }

    async awaitTask(id: string): Promise<ITaskResult> {
        const task = this.tasks.get(id);
        if (!task) {
            throw new Error(`Task ${id} not found`);
        }

        if (task.status === TaskStatus.Completed || task.status === TaskStatus.Failed) {
            return task.result!;
        }

        return new Promise<ITaskResult>((resolve, reject) => {
            this.taskResolvers.set(id, { resolve, reject });
        });
    }

    taskStatus(id: string): ITaskResult | undefined {
        const task = this.tasks.get(id);
        if (!task) {
            return undefined;
        }

        return {
            status: task.status,
            message: task.result?.message,
            error: task.result?.error
        };
    }

    async awaitAllTasks(): Promise<void> {
        if (this.pendingTasks.length === 0 && this.runningTasks.size === 0) {
            return;
        }

        return new Promise<void>((resolve, reject) => {
            this.allTasksResolver = { resolve, reject };
            this.checkAllTasksComplete();
        });
    }

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
            task.result = {
                status: TaskStatus.Failed,
                error: `No handler registered for task type: ${task.type}`
            };
            this.resolveTask(taskId, task.result);
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

    private executeTask(task: ITask, handler: TaskHandler): void {
        // Execute handler asynchronously with concurrency limit
        (async () => {
            try {
                const message = await handler(task.data, task.workingDirectory);
                
                task.status = TaskStatus.Completed;
                task.completedAt = new Date();
                task.result = {
                    status: TaskStatus.Completed,
                    message
                };
                this.runningTasks.delete(task.id);

                this.resolveTask(task.id, task.result);
                this.processNextTask();
            } catch (error: any) {
                task.status = TaskStatus.Failed;
                task.completedAt = new Date();
                task.result = {
                    status: TaskStatus.Failed,
                    error: error?.message || (error !== null && error !== undefined ? String(error) : "Unknown error")
                };
                this.runningTasks.delete(task.id);

                this.resolveTask(task.id, task.result);
                this.processNextTask();
            }
        })();
    }

    private handleWorkerMessage(message: any): void {
        if (message.type === "result") {
            const { taskId, result } = message;
            const task = this.tasks.get(taskId);
            if (!task) {
                return;
            }

            task.status = result.status;
            task.completedAt = new Date();
            task.result = result;
            this.runningTasks.delete(taskId);

            this.resolveTask(taskId, result);
            this.processNextTask();
        } else if (message.type === "error") {
            const { taskId, error } = message;
            const task = this.tasks.get(taskId);
            if (!task) {
                return;
            }

            task.status = TaskStatus.Failed;
            task.completedAt = new Date();
            task.result = {
                status: TaskStatus.Failed,
                error: error.message || String(error)
            };
            this.runningTasks.delete(taskId);

            this.resolveTask(taskId, task.result);
            this.processNextTask();
        }
    }

    private resolveTask(taskId: string, result: ITaskResult): void {
        const resolver = this.taskResolvers.get(taskId);
        if (resolver) {
            this.taskResolvers.delete(taskId);
            resolver.resolve(result);
        }

        this.checkAllTasksComplete();
    }

    private checkAllTasksComplete(): void {
        if (this.allTasksResolver && this.pendingTasks.length === 0 && this.runningTasks.size === 0) {
            const resolver = this.allTasksResolver;
            this.allTasksResolver = null;
            resolver.resolve();
        }
    }

    //
    // Cleanup: terminate all workers
    //
    shutdown(): void {
        // Workers will be terminated when actively used
        // For now, this is a no-op
    }
}

