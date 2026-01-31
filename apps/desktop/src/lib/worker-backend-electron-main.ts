import type { ITask, ITaskResult, IWorkerBackend, WorkerTaskCompletionCallback, TaskMessageCallback } from "task-queue";
import { TaskStatus } from "task-queue";
import { utilityProcess, type UtilityProcess } from 'electron';
import { deserializeError } from "serialize-error";
import type { IWorkerOptions } from "./worker-init";

//
// Worker message interface for communication between main thread and workers
//
export interface IWorkerMessage {
    type: "execute";
    taskId: string;
    taskType: string;
    data: unknown;
}

//
// Worker response message types
//
export interface IWorkerReadyMessage {
    type: "worker-ready";
}

export interface IWorkerTaskCompletedMessage {
    type: "task-completed";
    taskId: string;
    result: {
        status: "succeeded" | "failed";
        outputs?: unknown;
        error?: unknown;
        errorMessage?: string;
    };
}

export interface IWorkerTaskMessage {
    type: "task-message";
    taskId: string;
    message: unknown;
}

export type IWorkerResponseMessage = IWorkerReadyMessage | IWorkerTaskCompletedMessage | IWorkerTaskMessage;

//
// Worker state interface
//
interface IWorkerState {
    worker: UtilityProcess;
    workerId: number;
    isReady: boolean;
    isIdle: boolean;
    currentTaskId: string | null;
    currentTaskType: string | null;
    currentTaskRunningTimeMs: number | null;
    tasksProcessed: number;
    taskStartTime: number | null;
}

//
// Electron main process implementation of IWorkerBackend
// Uses utility processes to execute tasks in parallel
//
export class WorkerBackendElectronMain implements IWorkerBackend {
    private workers: IWorkerState[] = [];
    private maxWorkers: number;
    private peakWorkers: number = 0;
    private workerPath: string;
    private workerOptions: IWorkerOptions;
    private taskTimeout: number;
    private taskTimeouts: Map<string, NodeJS.Timeout> = new Map();
    private workerAvailableCallbacks: (() => void)[] = [];
    private completionCallbacks: WorkerTaskCompletionCallback[] = [];
    private messageCallbacks: Array<{ messageType: string; callback: TaskMessageCallback }> = [];
    private anyMessageCallbacks: TaskMessageCallback[] = [];
    private isShuttingDown: boolean = false;

    //
    // Creates a new worker backend with the specified number of utility process workers
    //
    constructor(workerPath: string, maxWorkers: number, taskTimeout: number, workerOptions: IWorkerOptions) {
        this.workerPath = workerPath;
        this.maxWorkers = maxWorkers;
        this.taskTimeout = taskTimeout;
        this.workerOptions = workerOptions;
    }

    //
    // Gets a summary of the worker pool.
    //
    getStatus() {
        return {
            peakWorkers: this.peakWorkers
        };
    }

    //
    // Registers a callback that will be called when a worker becomes available.
    //
    onWorkerAvailable(callback: () => void): () => void {
        this.workerAvailableCallbacks.push(callback);
        return () => {
            const index = this.workerAvailableCallbacks.indexOf(callback);
            if (index !== -1) {
                this.workerAvailableCallbacks.splice(index, 1);
            }
        };
    }

    //
    // Registers a callback that will be invoked whenever any task completes (success or failure).
    // Multiple callbacks can be registered and will all be called.
    //
    onTaskComplete(callback: WorkerTaskCompletionCallback): () => void {
        this.completionCallbacks.push(callback);
        return () => {
            const index = this.completionCallbacks.indexOf(callback);
            if (index !== -1) {
                this.completionCallbacks.splice(index, 1);
            }
        };
    }

    //
    // Registers a callback that will be called when a task sends messages to the client.
    // If messageType is provided, only messages with that type will be passed to the callback.
    //
    onTaskMessage(messageType: string, callback: TaskMessageCallback): () => void {
        const entry = { messageType, callback };
        this.messageCallbacks.push(entry);
        return () => {
            const index = this.messageCallbacks.indexOf(entry);
            if (index !== -1) {
                this.messageCallbacks.splice(index, 1);
            }
        };
    }

    //
    // Registers a callback that will be called for any task message, regardless of type.
    //
    onAnyTaskMessage(callback: TaskMessageCallback): () => void {
        this.anyMessageCallbacks.push(callback);
        return () => {
            const index = this.anyMessageCallbacks.indexOf(callback);
            if (index !== -1) {
                this.anyMessageCallbacks.splice(index, 1);
            }
        };
    }

    //
    // Notifies callback of worker availability.
    //
    private notifyWorkerAvailable(): void {
        for (const callback of this.workerAvailableCallbacks) {
            callback();
        }
    }

    //
    // Invokes all registered completion callbacks with the task result.
    // Callback errors are caught and logged to prevent breaking the queue.
    // Async callbacks are awaited to ensure they complete.
    //
    private async notifyCompletionCallbacks(result: ITaskResult): Promise<void> {
        for (const callback of this.completionCallbacks) {
            try {
                await callback(result);
            }
            catch (error: any) {
                console.error("Error in task completion callback:", error);
            }
        }
    }

    //
    // Invokes all registered message callbacks with the task message.
    // Only callbacks that match the message type (if specified) will be invoked.
    // Callback errors are caught and logged to prevent breaking the queue.
    // Async callbacks are awaited to ensure they complete.
    //
    private async notifyMessageCallbacks(taskId: string, message: any): Promise<void> {
        const messageType = message && typeof message === "object" && "type" in message ? message.type : undefined;

        for (const { messageType: filterType, callback } of this.messageCallbacks) {
            if (messageType !== filterType) {
                continue;
            }

            try {
                await callback({ taskId, message });
            }
            catch (error: any) {
                console.error("Error in task message callback:", error);
            }
        }

        for (const callback of this.anyMessageCallbacks) {
            try {
                await callback({ taskId, message });
            }
            catch (error: unknown) {
                console.error("Error in any task message callback:", error);
            }
        }
    }

    //
    // Creates a new utility process worker and sets up message handlers
    //
    private createWorker(): IWorkerState {
        const workerEnv: Record<string, string> = {};

        // Pass through temp directory environment variables
        if (process.env.TEMP) {
            workerEnv.TEMP = process.env.TEMP;
        }
        if (process.env.TMP) {
            workerEnv.TMP = process.env.TMP;
        }
        if (process.env.TMPDIR) {
            workerEnv.TMPDIR = process.env.TMPDIR;
        }

        const workerId = this.workers.length + 1;
        const workerOptionsWithId = {
            ...this.workerOptions,
            workerId,
        };
        workerEnv.WORKER_OPTIONS = JSON.stringify(workerOptionsWithId);

        const worker = utilityProcess.fork(this.workerPath, [], { env: workerEnv });
        const workerState: IWorkerState = {
            worker,
            workerId,
            isReady: false,
            isIdle: false,
            currentTaskId: null,
            currentTaskType: null,
            currentTaskRunningTimeMs: null,
            tasksProcessed: 0,
            taskStartTime: null,
        };

        worker.on('message', (message: IWorkerResponseMessage) => {
            this.handleWorkerMessage(workerState, message).catch((error: any) => {
                console.error("Error handling worker message", error);
            });
        });

        worker.on('spawn', () => {
            console.log(`Worker ${workerState.workerId} spawned`);
        });

        worker.on('exit', (code) => {
            // During shutdown, workers are terminated normally - don't treat as crash
            if (this.isShuttingDown) {
                return;
            }
            
            if (code !== 0) {
                console.error(`Worker ${workerState.workerId} exited with code ${code}`);
            }
            this.handleWorkerCrash(workerState);
        });

        this.workers.push(workerState);

        if (this.workers.length > this.peakWorkers) {
            this.peakWorkers = this.workers.length;
        }
        
        return workerState;
    }

    //
    // Handles messages from utility process workers (ready, task-completed, task-message)
    //
    private async handleWorkerMessage(workerState: IWorkerState, data: IWorkerResponseMessage): Promise<void> {
        // Handle worker ready message
        if (data && typeof data === "object" && "type" in data && data.type === "worker-ready") {
            workerState.isReady = true;
            workerState.isIdle = true;
            this.notifyWorkerAvailable(); // Try to process pending tasks now that worker is ready
            return;
        }

        // Handle task result (both success and failure)
        if (data && typeof data === "object" && "type" in data && data.type === "task-completed") {
            const { taskId, result } = data;

            // Clear timeout since task completed
            const timeout = this.taskTimeouts.get(taskId);
            if (timeout) {
                clearTimeout(timeout);
                this.taskTimeouts.delete(taskId);
            }

            // Determine if task failed
            const isFailed = result.status === "failed";
            
            // Build result object
            const fullResult: ITaskResult = {
                taskId: taskId,
                status: isFailed ? TaskStatus.Failed : TaskStatus.Succeeded,
            };

            if (isFailed) {
                let deserializedError: Error | undefined;
                if (result.error) {
                    try {
                        deserializedError = deserializeError(result.error);
                    }
                    catch {
                        // If deserialization fails, throw an error
                        throw new Error(`Failed to deserialize error: ${typeof result.error === 'string' ? result.error : JSON.stringify(result.error)}`);
                    }
                }
                else {
                    throw new Error("Task failed but no error provided");
                }
                fullResult.error = deserializedError;
                fullResult.errorMessage = deserializedError.message || "Unknown error";
            }
            else {
                fullResult.outputs = result.outputs;
            }

            // Update worker state
            workerState.isIdle = true;
            workerState.currentTaskId = null;
            workerState.currentTaskType = null;
            workerState.currentTaskRunningTimeMs = null;
            workerState.taskStartTime = null;
            workerState.tasksProcessed++;

            await this.notifyCompletionCallbacks(fullResult);
            return;
        }

        // Handle task messages
        if (data && typeof data === "object" && "type" in data && data.type === "task-message") {
            const { taskId, message } = data;

            // Notify message callbacks
            await this.notifyMessageCallbacks(taskId, message);
            return;
        }
    }

    //
    // Handles task timeout by marking the task as failed and killing the worker
    //
    private async handleTaskTimeout(taskId: string, workerState: IWorkerState): Promise<void> {
        // Clear the timeout (should already be cleared, but be safe)
        const timeout = this.taskTimeouts.get(taskId);
        if (timeout) {
            clearTimeout(timeout);
            this.taskTimeouts.delete(taskId);
        }

        console.error(`[Task Queue] Task ${taskId.substring(0, 2)}${taskId.substring(taskId.length - 2)} timed out after ${this.taskTimeout}ms`);

        // Terminate the worker
        try {
            workerState.worker.kill();
        }
        catch (error: any) {
            console.error(`[Task Queue] Error killing worker ${workerState.workerId}`, error);
        }

        const error = new Error("Task timeout");
        const result: ITaskResult = {
            taskId: taskId,
            status: TaskStatus.Failed,
            error: error,
            errorMessage: error.message,
        };

        workerState.isIdle = true;
        workerState.currentTaskId = null;
        workerState.currentTaskType = null;
        workerState.currentTaskRunningTimeMs = null;
        workerState.taskStartTime = null;

        await this.notifyCompletionCallbacks(result);

        // Replace the worker
        this.replaceWorker(workerState);
    }

    //
    // Handles worker crashes by terminating the worker and creating a replacement.
    // If the worker had a task, it will be requeued.
    //
    private handleWorkerCrash(workerState: IWorkerState): void {
        const crashedTaskId = workerState.currentTaskId;

        // Terminate the crashed worker
        try {
            workerState.worker.kill();
        }
        catch (e) {
            // Worker may already be terminated
        }

        // If worker had a task, clear its timeout and mark as failed
        if (crashedTaskId) {
            const timeout = this.taskTimeouts.get(crashedTaskId);
            if (timeout) {
                clearTimeout(timeout);
                this.taskTimeouts.delete(crashedTaskId);
            }

            const error = new Error("Worker crashed");
            const result: ITaskResult = {
                taskId: crashedTaskId,
                status: TaskStatus.Failed,
                error: error,
                errorMessage: error.message,
            };

            workerState.currentTaskId = null;
            workerState.currentTaskType = null;
            workerState.currentTaskRunningTimeMs = null;
            workerState.taskStartTime = null;
            this.notifyCompletionCallbacks(result);
        }

        // Replace the worker
        this.replaceWorker(workerState);
    }

    //
    // Replaces a worker with a new one
    //
    private replaceWorker(oldWorkerState: IWorkerState): void {
        // Remove from workers array
        const index = this.workers.indexOf(oldWorkerState);
        if (index > -1) {
            this.workers.splice(index, 1);
        }

        // Create replacement worker
        const workerEnv: Record<string, string> = {};

        // Pass through temp directory environment variables
        if (process.env.TEMP) {
            workerEnv.TEMP = process.env.TEMP;
        }
        if (process.env.TMP) {
            workerEnv.TMP = process.env.TMP;
        }
        if (process.env.TMPDIR) {
            workerEnv.TMPDIR = process.env.TMPDIR;
        }

        const workerOptionsWithId = {
            ...this.workerOptions,
            workerId: oldWorkerState.workerId,
        };
        workerEnv.WORKER_OPTIONS = JSON.stringify(workerOptionsWithId);

        const worker = utilityProcess.fork(this.workerPath, [], { env: workerEnv });
        const newWorkerState: IWorkerState = {
            worker,
            workerId: oldWorkerState.workerId,
            isReady: false,
            isIdle: false,
            currentTaskId: null,
            currentTaskType: null,
            currentTaskRunningTimeMs: null,
            tasksProcessed: oldWorkerState.tasksProcessed,
            taskStartTime: null,
        };

        worker.on('message', (message: IWorkerResponseMessage) => {
            this.handleWorkerMessage(newWorkerState, message).catch((error: any) => {
                console.error("Error handling worker message", error);
            });
        });

        worker.on('spawn', () => {
            console.log(`Worker ${newWorkerState.workerId} spawned`);
        });

        worker.on('exit', (code) => {
            // During shutdown, workers are terminated normally - don't treat as crash
            if (this.isShuttingDown) {
                return;
            }
            
            if (code !== 0) {
                console.error(`Worker ${newWorkerState.workerId} exited with code ${code}`);
            }
            this.handleWorkerCrash(newWorkerState);
        });

        this.workers.push(newWorkerState);
    }

    //
    // Dispatches as many tasks a possible to workers.
    // Returns true if the task was dispatched, false if no worker was available.
    //
    dispatchTask(task: ITask<any>): boolean {
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
            const workersNeeded = 1 - workersNotReadyYet; 
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
            return false;
        }
        
        if (!availableWorker) {
            return false; // All workers busy or not ready yet
        }

        availableWorker.isIdle = false;
        availableWorker.currentTaskId = task.id;
        availableWorker.currentTaskType = task.type;
        availableWorker.taskStartTime = Date.now();

        // Set up timeout for this task
        const timeoutId = setTimeout(() => {
            this.handleTaskTimeout(task.id, availableWorker!).catch((error: any) => {
                console.error("Error handling task timeout", error);
            });
        }, this.taskTimeout);
        this.taskTimeouts.set(task.id, timeoutId);

        // Send task to worker
        try {
            const executeMessage: IWorkerMessage = {
                type: "execute",
                taskId: task.id,
                taskType: task.type,
                data: task.data,
            };
            availableWorker.worker.postMessage(executeMessage);
        }
        catch (error: any) {
            console.error(`Error sending task to worker ${availableWorker.workerId}`, error);
            const timeout = this.taskTimeouts.get(task.id);
            if (timeout) {
                clearTimeout(timeout);
                this.taskTimeouts.delete(task.id);
            }
            this.handleWorkerCrash(availableWorker);
            return false;
        }

        return true;
    }

    //
    // Checks if all workers are idle.
    //
    isIdle(): boolean {
        return this.workers.every(w => w.isIdle);
    }

    //
    // Shuts down the worker backend and cleans up resources by terminating all workers
    //
    shutdown(): void {
        // Set shutdown flag to prevent exit handlers from treating normal termination as crashes
        this.isShuttingDown = true;
        
        // Clear all timeouts first to prevent any timeout callbacks from running
        for (const timeout of this.taskTimeouts.values()) {
            clearTimeout(timeout);
        }
        this.taskTimeouts.clear();

        for (const worker of this.workers) {
            try {
                worker.worker.kill();
            }
            catch (error) {
                console.error('Error killing worker:', error);
            }
        }
        this.workers = [];
    }
}

