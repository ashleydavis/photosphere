import { log } from "utils";
import { ITask, ITaskResult, IWorkerBackend, WorkerTaskCompletionCallback, TaskMessageCallback, TaskStatus } from "task-queue";

//
// Worker info interface for debugging and monitoring (Bun-specific)
//
export interface IWorkerInfo {
    workerId: number;
    isReady: boolean;
    isIdle: boolean;
    currentTaskId: string | null;
    currentTaskType: string | null;
    currentTaskRunningTimeMs: number | null;
    tasksProcessed: number;
}

//
// Callback for worker state changes (Bun-specific)
//
export type WorkerStateChangeCallback = (workers: IWorkerInfo[]) => void;

//
// Worker state interface
//
interface IWorkerState {
    worker: Worker;
    workerId: number;
    isReady: boolean; // Worker has sent "ready" message and can process tasks
    isIdle: boolean; // Worker is ready and not currently processing a task
    currentTaskId: string | null;
    currentTaskType: string | null;
    currentTaskRunningTimeMs: number | null;
    tasksProcessed: number; // Number of tasks this worker has completed (successful or failed)
    taskStartTime: number | null;
}


//
// Options passed to workers for context initialization
//
export interface IWorkerOptions {
    verbose?: boolean;
    tools?: boolean;
    sessionId?: string;
}

//
// Worker message interface for communication between main thread and workers
//
export interface IWorkerMessage {
    type: "execute";
    taskId: string;
    taskType: string;
    data: any;
}

//
// Worker response message types
//
interface IWorkerReadyMessage {
    type: "worker-ready";
}

interface IWorkerTaskCompletedMessage {
    type: "task-completed";
    taskId: string;
    result: ITaskResult;
}

interface IWorkerTaskMessage {
    type: "task-message";
    taskId: string;
    message: any;
}

type IWorkerResponseMessage = IWorkerReadyMessage | IWorkerTaskCompletedMessage | IWorkerTaskMessage;

//
// Manages workers on Bun.
//
export class WorkerBackendBun implements IWorkerBackend {

    private workers: IWorkerState[] = [];
    private maxWorkers: number;
    private peakWorkers: number = 0;
    private workerOptions: IWorkerOptions;
    private workerStateChangeCallback: WorkerStateChangeCallback | null = null;
    private taskTimeout: number;
    private taskTimeouts: Map<string, NodeJS.Timeout> = new Map();
    private workerAvailableCallbacks: (() => void)[] = [];
    private completionCallbacks: WorkerTaskCompletionCallback[] = [];
    private messageCallbacks: Array<{ messageType: string; callback: TaskMessageCallback }> = [];
    private anyMessageCallbacks: TaskMessageCallback[] = [];

    //
    // Creates a new task queue with the specified number of workers.
    // Tasks will execute in separate Bun worker threads for true parallelism.
    // taskTimeout: Timeout in milliseconds for tasks (default: 10 minutes = 600000ms).
    // workerOptions: Options to pass to workers for logging and context initialization.
    //
    constructor(maxWorkers: number, taskTimeout: number, workerOptions: IWorkerOptions) {
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
        const entry = { messageType, callback: callback };
        this.messageCallbacks.push(entry);
        return () => {
            const index = this.messageCallbacks.indexOf(entry);
            if (index !== -1) {
                this.messageCallbacks.splice(index, 1);
            }
        };
    }

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
    // Gets current state of all workers for debugging.
    //
    getWorkerState(): IWorkerInfo[] {
        return this.workers.map(worker => {
            const runningTime = worker.taskStartTime //todo: If the UI could do this calculation wouldn't have to do this map here.
                ? Date.now() - worker.taskStartTime
                : null;

            return {
                workerId: worker.workerId,
                isReady: worker.isReady,
                isIdle: worker.isIdle,
                currentTaskId: worker.currentTaskId,
                currentTaskType: worker.currentTaskType,
                currentTaskRunningTimeMs: runningTime,
                tasksProcessed: worker.tasksProcessed,
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
                // Don't let callback errors break the task queue
                log.exception("Error in task completion callback", error);
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
    // Notifies callback of worker state changes.
    //
    private notifyWorkerStateChange(): void {
        if (this.workerStateChangeCallback) {
            this.workerStateChangeCallback(this.getWorkerState());
        }
    }

    //
    // Creates a single worker and adds it to the pool.
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
        
        // Pass through PATH so workers can find binaries (e.g., ImageMagick in /opt/homebrew/bin on macOS ARM64)
        if (process.env.PATH) {
            workerEnv.PATH = process.env.PATH;
        }
        
        workerEnv.WORKER_OPTIONS = JSON.stringify(this.workerOptions);
        
        const worker = new Worker("./worker.ts", { env: workerEnv });
        const workerState: IWorkerState = {
            worker,
            workerId: this.workers.length + 1,
            isReady: false, // Will be set to true when worker sends "ready" message
            isIdle: false, // Will be set to true when worker is ready and idle
            currentTaskId: null,
            currentTaskType: null,
            currentTaskRunningTimeMs: null,
            tasksProcessed: 0,
            taskStartTime: null,
        };

        worker.addEventListener("message", (event: MessageEvent) => {
            this.handleWorkerMessage(workerState, event.data as IWorkerResponseMessage).catch((error: any) => {
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

        if (this.workers.length > this.peakWorkers) {
            this.peakWorkers = this.workers.length;
        }
        
        this.notifyWorkerStateChange();
        return workerState;
    }


    //
    // Replaces a worker with a new one.
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
        
        // Pass through PATH so workers can find binaries (e.g., ImageMagick in /opt/homebrew/bin on macOS ARM64)
        if (process.env.PATH) {
            workerEnv.PATH = process.env.PATH;
        }
        
        workerEnv.WORKER_OPTIONS = JSON.stringify(this.workerOptions);
        
        const worker = new Worker("./worker.ts", { env: workerEnv });
        const newWorkerState: IWorkerState = {
            worker,
            workerId: oldWorkerState.workerId,
            isReady: false, // Will be set to true when worker sends "ready" message
            isIdle: false,
            currentTaskId: null,
            currentTaskType: null,
            currentTaskRunningTimeMs: null,
            tasksProcessed: oldWorkerState.tasksProcessed, // Preserve task count when replacing worker
            taskStartTime: null,
        };

        worker.addEventListener("message", (event: MessageEvent) => {
            this.handleWorkerMessage(newWorkerState, event.data as IWorkerResponseMessage).catch((error: any) => {
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
    // Handles messages from worker threads.
    // Processes task results and errors.
    //
    private async handleWorkerMessage(workerState: IWorkerState, data: IWorkerResponseMessage): Promise<void> {
        // Handle worker ready message
        if (data && typeof data === "object" && "type" in data && data.type === "worker-ready") {
            workerState.isReady = true;
            workerState.isIdle = true;
            this.notifyWorkerStateChange();
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
            
            // Build result object
            const fullResult: ITaskResult = {
                taskId: taskId,
                status: result.status,
                error: result.error,
                errorMessage: result.error?.message || "Unknown error",
                outputs: result.outputs,
            };

            // Update worker state
            workerState.isIdle = true;
            workerState.currentTaskId = null;
            workerState.currentTaskType = null;
            workerState.currentTaskRunningTimeMs = null;
            workerState.taskStartTime = null;
            workerState.tasksProcessed++;

            this.notifyWorkerStateChange();
            await this.notifyCompletionCallbacks(fullResult);
            return;
        }

        // Handle task message
        if (data && typeof data === "object" && "type" in data && data.type === "task-message") {
            const { taskId, message } = data;
            await this.notifyMessageCallbacks(taskId, message);
            return;
        }
    }

    //
    // Handles task timeout by terminating the worker and marking the task as failed.
    //
    private async handleTaskTimeout(taskId: string, workerState: IWorkerState): Promise<void> {
        // Clear the timeout (should already be cleared, but be safe)
        const timeout = this.taskTimeouts.get(taskId);
        if (timeout) {
            clearTimeout(timeout);
            this.taskTimeouts.delete(taskId);
        }

        log.error(`[Task Queue] Task ${taskId} timed out after ${this.taskTimeout}ms`);

        // Terminate the worker
        try {
            workerState.worker.terminate();
        } 
        catch (error: any) {
            log.exception(`[Task Queue] Error terminating worker ${workerState.workerId}`, error);
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
            workerState.worker.terminate();
        } catch (e) {
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
    // Dispatches as many tasks a possible to workers.
    // Returns true if the task was dispatched, false if no worker was available.
    //
    dispatchTask(task: ITask<any>): boolean {
        //
        // Find an available idle worker that has processed the least tasks
        //
        const idleWorkers = this.workers.filter(w => w.isIdle);
        let availableWorker = idleWorkers.length > 0
            ? idleWorkers.reduce((least, current) => 
                current.tasksProcessed < least.tasksProcessed ? current : least
            )
            : undefined;
        
        //
        // If no idle worker available and we haven't reached maxWorkers, create workers for pending tasks
        //
        if (!availableWorker && this.workers.length < this.maxWorkers) {
            
            // Calculate how many workers we need: pending tasks minus workers that will become available
            const workersNeeded = 1; 
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
        this.notifyWorkerStateChange();

        // Set up timeout for this task
        const timeoutId = setTimeout(() => {
            this.handleTaskTimeout(task.id, availableWorker!).catch((error: any) => {
                log.exception("Error handling task timeout", error);
            });
        }, this.taskTimeout);
        this.taskTimeouts.set(task.id, timeoutId);

        // Send task to worker
        try {
            const executeMsg: IWorkerMessage = {
                type: "execute",
                taskId: task.id,
                taskType: task.type,
                data: task.data,
            };
            availableWorker.worker.postMessage(executeMsg);
        } 
        catch (error: any) {
            log.exception(`Error sending task to worker ${availableWorker.workerId}`, error);

            // Clear timeout on error
            const timeout = this.taskTimeouts.get(task.id);
            if (timeout) {
                clearTimeout(timeout);
                this.taskTimeouts.delete(task.id);
            }
            this.handleWorkerCrash(availableWorker);
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
    // Shuts down all the workers.
    //
    shutdown(): void {
        // Clear all timeouts first to prevent any timeout callbacks from running
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