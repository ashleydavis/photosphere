import { join } from "node:path";
import { IUuidGenerator, log } from "utils";
import { deserializeError } from "serialize-error";
import { TaskStatus, type ITaskResult, type ITaskQueue, type TaskCompletionCallback, type TaskMessageCallback, type WorkerStateChangeCallback, type IWorkerInfo } from "task-queue";
import type { IWorkerOptions } from "./worker-init";

//
// Worker message interface for communication between main thread and workers
//
export interface IWorkerMessage {
    type: "execute";
    taskId: string;
    taskType: string;
    data: any;
    workingDirectory: string;
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
    timeoutCount: number; // Track number of times this task has timed out
}

//
// Worker state interface
//
interface IWorkerState {
    worker: Worker;
    workerId: number;
    isReady: boolean; // Worker has sent "ready" message and can process tasks
    isIdle: boolean; // Worker is ready and not currently processing a task
    currentTaskId: string | null;
    tasksProcessed: number; // Number of tasks this worker has completed (successful or failed)
}

//
// Task queue implementation using Bun workers
//
export class TaskQueue implements ITaskQueue {
    private tasks: Map<string, ITask> = new Map();
    private pendingTasks: string[] = [];
    private workers: IWorkerState[] = [];
    private maxWorkers: number;
    private peakWorkers: number = 0;
    private baseWorkingDirectory: string;
    private uuidGenerator: IUuidGenerator;
    private allTasksResolver: { resolve: () => void; reject: (error: Error) => void } | null = null;
    private completionCallbacks: TaskCompletionCallback<any, any>[] = [];
    private messageCallbacks: Array<{ messageType: string; callback: TaskMessageCallback<any> }> = [];
    private anyMessageCallbacks: TaskMessageCallback<any>[] = [];
    private tasksQueued: number = 0;
    private tasksPending: number = 0;
    private tasksRunning: number = 0;
    private tasksCompleted: number = 0;
    private tasksFailed: number = 0;
    private taskTimeout: number;
    private taskTimeouts: Map<string, NodeJS.Timeout> = new Map();
    private workerOptions: IWorkerOptions;
    private workerStateChangeCallback: WorkerStateChangeCallback | null = null;

    //
    // Creates a new task queue with the specified number of workers.
    // Tasks will execute in separate Bun worker threads for true parallelism.
    // taskTimeout: Timeout in milliseconds for tasks (default: 10 minutes = 600000ms).
    // workerOptions: Options to pass to workers for logging and context initialization.
    //
    constructor(maxWorkers: number, baseWorkingDirectory: string, uuidGenerator: IUuidGenerator, taskTimeout: number, workerOptions: IWorkerOptions) {
        this.maxWorkers = maxWorkers;
        this.baseWorkingDirectory = baseWorkingDirectory;
        this.uuidGenerator = uuidGenerator;
        this.taskTimeout = taskTimeout;
        this.workerOptions = workerOptions;
    }

    //
    // Adds a task to the queue to be executed. Returns the task ID (UUID).
    // The task will be executed when a worker becomes available.
    //
    addTask(type: string, data: any, taskId?: string): string {
        const id = taskId || this.uuidGenerator.generate();
        const workingDirectory = join(this.baseWorkingDirectory, id);

        const task: ITask = {
            id,
            type,
            status: TaskStatus.Pending,
            data,
            workingDirectory,
            createdAt: new Date(),
            timeoutCount: 0
        };

        this.tasks.set(id, task);
        this.pendingTasks.push(id);
        this.tasksQueued++;
        this.tasksPending++;
        this.processNextTask();

        return id;
    }

    //
    // Registers a callback that will be invoked whenever any task completes (success or failure).
    // Multiple callbacks can be registered and will all be called.
    //
    onTaskComplete<TInputs = any, TOutputs = any>(callback: TaskCompletionCallback<TInputs, TOutputs>): void {
        this.completionCallbacks.push(callback as TaskCompletionCallback<any, any>);
    }

    //
    // Adds a task and waits for it to complete, returning the outputs.
    // Throws an error if the task fails.
    //
    async awaitTask<TInputs = any, TOutputs = any>(type: string, data: TInputs): Promise<TOutputs> {
        const taskId = this.addTask(type, data);

        return new Promise<TOutputs>((resolve, reject) => {
            let resolved = false;

            const resolveOnce = (value: TOutputs) => {
                if (!resolved) {
                    resolved = true;
                    resolve(value);
                }
            };

            const rejectOnce = (error: Error) => {
                if (!resolved) {
                    resolved = true;
                    reject(error);
                }
            };

            // Set up listener for task completion/errors
            this.onTaskComplete<TInputs, TOutputs>((taskResult) => {
                // Verify this is the correct task by checking taskId matches
                if (taskResult.taskId !== taskId) {
                    return; // This is a different task, ignore it
                }

                if (taskResult.status === TaskStatus.Failed) {
                    rejectOnce(new Error(taskResult.errorMessage || "Task failed"));
                }
                else {
                    resolveOnce(taskResult.outputs as TOutputs);
                }
            });
        });
    }

    //
    // Waits for all pending and running tasks to complete.
    // Resolves when the queue is empty (no pending or running tasks).
    //
    async awaitAllTasks(): Promise<void> {
        const runningCount = this.workers.filter(w => !w.isIdle).length;
        if (this.pendingTasks.length === 0 && runningCount === 0) {
            return;
        }

        return new Promise<void>((resolve, reject) => {
            this.allTasksResolver = { resolve, reject };
            this.checkAllTasksComplete();
        });
    }

    //
    // Gets a summary of the queue status: counts of pending, running, completed, and failed tasks.
    // Includes execution statistics: tasks queued, peak workers, completed, and failed.
    // Useful for monitoring and progress tracking.
    //
    getStatus() {
        return {
            pending: this.tasksPending,
            running: this.tasksRunning,
            completed: this.tasksCompleted,
            failed: this.tasksFailed,
            total: this.tasks.size + this.tasksCompleted + this.tasksFailed,
            tasksQueued: this.tasksQueued,
            peakWorkers: this.peakWorkers
        };
    }

    //
    // Gets current state of all workers for debugging.
    //
    getWorkerState(): IWorkerInfo[] {
        return this.workers.map(worker => {
            let currentTaskRunningTimeMs: number | null = null;
            if (worker.currentTaskId) {
                const task = this.tasks.get(worker.currentTaskId);
                if (task && task.startedAt) {
                    currentTaskRunningTimeMs = Date.now() - task.startedAt.getTime();
                }
            }
            
            return {
                workerId: worker.workerId,
                isReady: worker.isReady,
                isIdle: worker.isIdle,
                currentTaskId: worker.currentTaskId,
                currentTaskType: worker.currentTaskId ? this.tasks.get(worker.currentTaskId)?.type || null : null,
                currentTaskRunningTimeMs,
                tasksProcessed: worker.tasksProcessed
            };
        });
    }

    //
    // Sets a callback to be notified when worker state changes.
    //
    onWorkerStateChange(callback: WorkerStateChangeCallback): void {
        this.workerStateChangeCallback = callback;
    }

    //
    // Registers a callback that will be called when a task sends messages to the client.
    // If messageType is provided, only messages with that type will be passed to the callback.
    //
    onTaskMessage<TMessage = any>(messageType: string, callback: TaskMessageCallback<TMessage>): void {
        this.messageCallbacks.push({ messageType, callback: callback as TaskMessageCallback<any> });
    }

    onAnyTaskMessage<TMessage = any>(callback: TaskMessageCallback<TMessage>): void {
        this.anyMessageCallbacks.push(callback as TaskMessageCallback<any>);
    }

    //
    // Internal: Notifies callback of worker state changes.
    //
    private notifyWorkerStateChange(): void {
        if (this.workerStateChangeCallback) {
            this.workerStateChangeCallback(this.getWorkerState());
        }
    }

    //
    // Internal: Creates a single worker and adds it to the pool.
    // Returns the worker state.
    //
    private createWorker(): IWorkerState {
        // Pass worker options via environment variable
        // Also pass through environment variables needed for tmpdir() to work correctly
        const workerEnv: Record<string, string> = {};
        
        // Pass through temp directory environment variables (needed for os.tmpdir() to work)
        if (process.env.TEMP) {
            workerEnv.TEMP = process.env.TEMP;
        }
        if (process.env.TMP) {
            workerEnv.TMP = process.env.TMP;
        }
        if (process.env.TMPDIR) {
            workerEnv.TMPDIR = process.env.TMPDIR;
        }
        
        workerEnv.WORKER_OPTIONS = JSON.stringify(this.workerOptions);
        
        const worker = new Worker("./worker.ts", { env: workerEnv });
        const workerState: IWorkerState = {
            worker,
            workerId: this.workers.length + 1,
            isReady: false, // Will be set to true when worker sends "ready" message
            isIdle: false, // Will be set to true when worker is ready and idle
            currentTaskId: null,
            tasksProcessed: 0
        };

        worker.addEventListener("message", (event: MessageEvent) => {
            this.handleWorkerMessage(workerState, event.data).catch((error: any) => {
                log.exception("Error handling worker message", error);
            });
        });

        worker.addEventListener("error", (error: any) => {
            log.exception(`Error from worker ${workerState.workerId}`, error);
            this.handleWorkerCrash(workerState);
        });

        worker.addEventListener("messageerror", (error: any) => {
            log.exception(`Error from worker ${workerState.workerId}`, error);
            this.handleWorkerCrash(workerState);
        });

        this.workers.push(workerState);

        // Update peak workers count
        if (this.workers.length > this.peakWorkers) {
            this.peakWorkers = this.workers.length;
        }
        this.notifyWorkerStateChange();
        return workerState;
    }

    //
    // Internal: Processes the next pending task if a worker is available.
    // Called automatically when tasks are added or completed.
    // Creates workers lazily if needed (up to maxWorkers limit).
    //
    private processNextTask(): void {
        if (this.pendingTasks.length === 0) {
            this.checkAllTasksComplete();
            return;
        }

        // Find an available idle worker that has processed the least tasks
        const idleWorkers = this.workers.filter(w => w.isIdle);
        let availableWorker = idleWorkers.length > 0
            ? idleWorkers.reduce((least, current) => 
                current.tasksProcessed < least.tasksProcessed ? current : least
            )
            : undefined;
        
        // If no idle worker available and we haven't reached maxWorkers, create workers for pending tasks
        if (!availableWorker && this.workers.length < this.maxWorkers) {
            // Count workers that are not ready yet (will become available soon)
            // These workers will be able to process tasks once they're ready, so we should account for them
            let workersNotReadyYet = 0;
            for (const worker of this.workers) {
                if (!worker.isReady) {
                    workersNotReadyYet++;
                }
            }
            
            // Calculate how many workers we need: pending tasks minus workers that will become available
            const workersNeeded = this.pendingTasks.length - workersNotReadyYet; 
            if (workersNeeded > 0) {
                // Create workers for the tasks that need them, up to maxWorkers limit
                const workersToCreate = Math.min(
                    workersNeeded,
                    this.maxWorkers - this.workers.length
                );
                
                for (let i = 0; i < workersToCreate; i++) {
                    this.createWorker();
                }
            }
            
            // Workers won't be idle until they send "ready" messages, so return for now
            return;
        }
        
        if (!availableWorker) {
            return; // All workers busy or not ready yet
        }

        const taskId = this.pendingTasks.shift()!;
        const task = this.tasks.get(taskId);
        if (!task) {
            return;
        }

        // Mark task as running and assign to worker
        task.status = TaskStatus.Running;
        task.startedAt = new Date();
        this.tasksPending--;
        this.tasksRunning++;
        availableWorker.isIdle = false;
        availableWorker.currentTaskId = taskId;
        this.notifyWorkerStateChange();

        // Set up timeout for this task
        const timeoutId = setTimeout(() => {
            this.handleTaskTimeout(taskId, availableWorker!).catch((error: any) => {
                log.exception("Error handling task timeout", error);
            });
        }, this.taskTimeout);
        this.taskTimeouts.set(taskId, timeoutId);

        // Send task to worker
        try {
            const executeMsg: IWorkerMessage = {
                type: "execute",
                taskId: task.id,
                taskType: task.type,
                data: task.data,
                workingDirectory: task.workingDirectory,
            };
            availableWorker.worker.postMessage(executeMsg);
        } 
        catch (error: any) {
            log.exception(`Error sending task to worker ${availableWorker.workerId}`, error);
            // Clear timeout on error
            const timeout = this.taskTimeouts.get(taskId);
            if (timeout) {
                clearTimeout(timeout);
                this.taskTimeouts.delete(taskId);
            }
            this.handleWorkerCrash(availableWorker);
        }
    }

    //
    // Internal: Handles messages from worker threads.
    // Processes task results and errors.
    //
    private async handleWorkerMessage(workerState: IWorkerState, data: any): Promise<void> {
        // Handle worker ready message
        if (data && typeof data === "object" && "type" in data && data.type === "ready") {
            workerState.isReady = true;
            workerState.isIdle = true;
            this.notifyWorkerStateChange();
            this.processNextTask(); // Try to process pending tasks now that worker is ready
            return;
        }

        // Handle task result
        if (data && typeof data === "object" && "type" in data && data.type === "task-completed") {
            const { taskId, result } = data;
            const task = this.tasks.get(taskId);
            if (!task) {
                return;
            }

            // Clear timeout since task completed successfully
            const timeout = this.taskTimeouts.get(taskId);
            if (timeout) {
                clearTimeout(timeout);
                this.taskTimeouts.delete(taskId);
            }

            task.status = TaskStatus.Completed;
            task.completedAt = new Date();
            this.tasksRunning--;
            this.tasksCompleted++;
            const fullResult: ITaskResult = {
                status: TaskStatus.Completed,
                outputs: result.outputs,
                inputs: task.data,
                taskId: task.id,
                taskType: task.type,
                createdAt: task.createdAt,
                startedAt: task.startedAt,
                completedAt: task.completedAt
            };
            task.result = fullResult;

            workerState.isIdle = true;
            workerState.currentTaskId = null;
            workerState.tasksProcessed++;

            this.notifyWorkerStateChange();
            await this.notifyCompletionCallbacks(fullResult);
            this.resolveTask(taskId, fullResult);
            
            // Remove completed task from memory after reporting result
            this.tasks.delete(taskId);
            
            this.processNextTask();
            return;
        }

        // Handle task message
        if (data && typeof data === "object" && "type" in data && data.type === "message") {
            const { taskId, message } = data;
            await this.notifyMessageCallbacks(taskId, message);
            return;
        }

        // Handle task error
        if (data && typeof data === "object" && "type" in data && data.type === "error") {
            const { taskId, error } = data;
            const task = this.tasks.get(taskId);
            if (!task) {
                return;
            }

            // Clear timeout since task completed (with error)
            const timeout = this.taskTimeouts.get(taskId);
            if (timeout) {
                clearTimeout(timeout);
                this.taskTimeouts.delete(taskId);
            }

            task.status = TaskStatus.Failed;
            task.completedAt = new Date();
            this.tasksRunning--;
            this.tasksFailed++;
            let deserializedError: Error | undefined;
            if (error) {
                try {
                    deserializedError = deserializeError(error);
                } 
                catch {
                    // If deserialization fails, create a generic error
                    deserializedError = new Error(typeof error === 'string' ? error : JSON.stringify(error));
                }
            } else {
                deserializedError = new Error("Unknown error");
            }
            const result: ITaskResult = {
                status: TaskStatus.Failed,
                error: deserializedError,
                errorMessage: deserializedError.message || "Unknown error",
                inputs: task.data,
                taskId: task.id,
                taskType: task.type,
                createdAt: task.createdAt,
                startedAt: task.startedAt,
                completedAt: task.completedAt
            };
            task.result = result;

            workerState.isIdle = true;
            workerState.currentTaskId = null;
            workerState.tasksProcessed++;

            this.notifyWorkerStateChange();
            await this.notifyCompletionCallbacks(result);
            this.resolveTask(taskId, result);
            
            // Remove failed task from memory after reporting result
            this.tasks.delete(taskId);
            
            this.processNextTask();
            return;
        }
    }

    //
    // Internal: Handles task timeout by terminating the worker, requeuing the task, and replacing the worker.
    // Only allows up to 3 timeouts per task, after which the task is marked as failed.
    //
    private async handleTaskTimeout(taskId: string, workerState: IWorkerState): Promise<void> {
        const task = this.tasks.get(taskId);
        if (!task || task.status !== TaskStatus.Running) {
            // Task already completed or doesn't exist, ignore timeout
            return;
        }

        // Clear the timeout (should already be cleared, but be safe)
        const timeout = this.taskTimeouts.get(taskId);
        if (timeout) {
            clearTimeout(timeout);
            this.taskTimeouts.delete(taskId);
        }

        // Increment timeout count
        task.timeoutCount++;

        log.error(`[Task Queue] Task ${this.formatTaskId(taskId)} timed out after ${this.taskTimeout}ms (timeout count: ${task.timeoutCount}/3)`);

        // Terminate the worker
        try {
            workerState.worker.terminate();
        } 
        catch (error: any) {
            log.exception(`[Task Queue] Error terminating worker ${workerState.workerId}`, error);
        }

        // Check if we've exceeded the maximum number of timeouts
        if (task.timeoutCount >= 3) {
            // Mark task as failed after 3 timeouts
            task.status = TaskStatus.Failed;
            task.completedAt = new Date();
            this.tasksRunning--;
            this.tasksFailed++;
            const error = new Error(`Task timed out ${task.timeoutCount} times (exceeded maximum of 3)`);
            const result: ITaskResult = {
                status: TaskStatus.Failed,
                error: error,
                errorMessage: error.message,
                inputs: task.data,
                taskId: task.id,
                taskType: task.type,
                createdAt: task.createdAt,
                startedAt: task.startedAt,
                completedAt: task.completedAt
            };
            task.result = result;

            workerState.isIdle = true;
            workerState.currentTaskId = null;

            await this.notifyCompletionCallbacks(result);
            this.resolveTask(taskId, result);
            this.processNextTask();

            // Replace the worker
            this.replaceWorker(workerState);
        } else {
            // Requeue the task for retry
            task.status = TaskStatus.Pending;
            task.startedAt = undefined;
            this.tasksRunning--;
            this.tasksPending++;
            this.pendingTasks.unshift(taskId); // Add to front of queue for priority

            // Replace the worker
            this.replaceWorker(workerState);
        }
    }

    //
    // Internal: Handles worker crashes by terminating the worker and creating a replacement.
    // If the worker had a task, it will be requeued.
    //
    private handleWorkerCrash(workerState: IWorkerState): void {
        const crashedTaskId = workerState.currentTaskId;

        // Terminate the crashed worker
        try {
            workerState.worker.terminate();
        } catch (e) {
            // Worker may already be terminated
        }

        // If worker had a task, clear its timeout and requeue it
        if (crashedTaskId) {
            const timeout = this.taskTimeouts.get(crashedTaskId);
            if (timeout) {
                clearTimeout(timeout);
                this.taskTimeouts.delete(crashedTaskId);
            }

            const task = this.tasks.get(crashedTaskId);
            if (task && task.status === TaskStatus.Running) {
                task.status = TaskStatus.Pending;
                task.startedAt = undefined;
                this.tasksRunning--;
                this.tasksPending++;
                this.pendingTasks.unshift(crashedTaskId); // Add to front of queue for priority
            }
        }

        // Replace the worker
        this.replaceWorker(workerState);
    }

    //
    // Internal: Replaces a worker with a new one.
    //
    private replaceWorker(oldWorkerState: IWorkerState): void {
        // Remove from workers array
        const index = this.workers.indexOf(oldWorkerState);
        if (index > -1) {
            this.workers.splice(index, 1);
            this.notifyWorkerStateChange();
        }

        // Create replacement worker
        // Pass worker options via environment variable
        // Also pass through environment variables needed for tmpdir() to work correctly
        const workerEnv: Record<string, string> = {};
        
        // Pass through temp directory environment variables (needed for os.tmpdir() to work)
        if (process.env.TEMP) {
            workerEnv.TEMP = process.env.TEMP;
        }
        if (process.env.TMP) {
            workerEnv.TMP = process.env.TMP;
        }
        if (process.env.TMPDIR) {
            workerEnv.TMPDIR = process.env.TMPDIR;
        }
        
        workerEnv.WORKER_OPTIONS = JSON.stringify(this.workerOptions);
        
        const worker = new Worker("./worker.ts", { env: workerEnv });
        const newWorkerState: IWorkerState = {
            worker,
            workerId: oldWorkerState.workerId,
            isReady: false, // Will be set to true when worker sends "ready" message
            isIdle: false,
            currentTaskId: null,
            tasksProcessed: oldWorkerState.tasksProcessed // Preserve task count when replacing worker
        };

        worker.addEventListener("message", (event: MessageEvent) => {
            this.handleWorkerMessage(newWorkerState, event.data).catch((error: any) => {
                log.exception("Error handling worker message", error);
            });
        });

        worker.addEventListener("error", (error: any) => {
            log.exception(`Error from worker ${newWorkerState.workerId}`, error);
            this.handleWorkerCrash(newWorkerState);
        });

        worker.addEventListener("messageerror", (error: any) => {
            log.exception(`Error from worker ${newWorkerState.workerId}]`, error);
            this.handleWorkerCrash(newWorkerState);
        });

        this.workers.push(newWorkerState);
        this.notifyWorkerStateChange();
    }

    //
    // Internal: Invokes all registered completion callbacks with the task result.
    // Callback errors are caught and logged to prevent breaking the queue.
    // Async callbacks are awaited to ensure they complete.
    //
    private async notifyCompletionCallbacks(result: ITaskResult): Promise<void> {
        for (const callback of this.completionCallbacks) {
            try {
                await callback(result);
            } 
            catch (error: any) {
                // Don't let callback errors break the task queue
                log.exception("Error in task completion callback", error);
            }
        }
    }

    //
    // Internal: Invokes all registered message callbacks with the task message.
    // Only callbacks that match the message type (if specified) will be invoked.
    // Callback errors are caught and logged to prevent breaking the queue.
    // Async callbacks are awaited to ensure they complete.
    //
    private async notifyMessageCallbacks(taskId: string, message: any): Promise<void> {
        const messageType = message && typeof message === "object" && "type" in message ? message.type : undefined;
        
        // Notify callbacks registered for specific message types
        for (const { messageType: filterType, callback } of this.messageCallbacks) {
            if (messageType !== filterType) {
                continue;
            }
            
            try {
                await callback({ taskId, message });
            }
            catch (error: any) {
                // Don't let callback errors break the task queue
                log.exception("Error in task message callback", error);
            }
        }
        
        // Notify callbacks registered for any message type
        for (const callback of this.anyMessageCallbacks) {
            try {
                await callback({ taskId, message });
            }
            catch (error: any) {
                // Don't let callback errors break the task queue
                log.exception("Error in any task message callback", error);
            }
        }
    }


    //
    // Internal: Checks if all tasks are complete to resolve awaitAllTasks().
    //
    private resolveTask(taskId: string, result: ITaskResult): void {
        this.checkAllTasksComplete();
    }

    //
    // Internal: Checks if all tasks are complete and resolves awaitAllTasks() if so.
    // Called after each task completes.
    //
    private checkAllTasksComplete(): void {
        const runningCount = this.workers.filter(w => !w.isIdle).length;
        if (this.allTasksResolver && this.pendingTasks.length === 0 && runningCount === 0) {
            const resolver = this.allTasksResolver;
            this.allTasksResolver = null;
            resolver.resolve();
        }
    }

    //
    // Formats a task ID to show only first 2 and last 2 characters.
    // Example: "12345678-1234-1234-1234-123456789abc" -> "12bc"
    //
    private formatTaskId(taskId: string): string {
        if (taskId.length <= 4) {
            return taskId;
        }
        return `${taskId.substring(0, 2)}${taskId.substring(taskId.length - 2)}`;
    }

    //
    // Shuts down the task queue and cleans up resources.
    // Terminates all workers and should be called when the queue is no longer needed.
    //
    shutdown(): void {
        // Clear all timeouts
        for (const timeout of this.taskTimeouts.values()) {
            clearTimeout(timeout);
        }
        this.taskTimeouts.clear();

        for (const workerState of this.workers) {
            try {
                workerState.worker.terminate();
            } catch (e) {
                // Ignore termination errors
            }
        }
        this.workers = [];
    }
}

