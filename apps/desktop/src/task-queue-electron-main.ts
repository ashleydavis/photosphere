import type { ITaskQueue, IQueueStatus, IWorkerInfo } from "task-queue";
import { TaskStatus, type ITaskResult, type TaskCompletionCallback, type WorkerStateChangeCallback, type TaskMessageCallback } from "task-queue";
import { utilityProcess, type UtilityProcess } from 'electron';
import { deserializeError } from "serialize-error";
import type { IWorkerOptions } from "./lib/worker-init";
import type { IUuidGenerator, ITimestampProvider } from "utils";

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
interface IWorkerReadyMessage {
    type: "worker-ready";
}

interface IWorkerTaskCompletedMessage {
    type: "task-completed";
    taskId: string;
    result: {
        outputs?: unknown;
        status?: "failed";
        error?: unknown;
    };
}

interface IWorkerTaskMessage {
    type: "task-message";
    taskId: string;
    message: unknown;
}

type IWorkerResponseMessage = IWorkerReadyMessage | IWorkerTaskCompletedMessage | IWorkerTaskMessage;

//
// Task interface
//
interface ITask {
    id: string;
    type: string;
    data: any;
    status: TaskStatus;
    createdAt: Date;
    startedAt?: Date;
    completedAt?: Date;
}

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
// Electron main process implementation of ITaskQueue
// Uses utility processes to execute tasks in parallel
//
export class TaskQueueElectronMain implements ITaskQueue {
    private tasks: Map<string, ITask> = new Map();
    private pendingTasks: string[] = [];
    private workers: IWorkerState[] = [];
    private maxWorkers: number;
    private peakWorkers: number = 0;
    private workerPath: string;
    private uuidGenerator: IUuidGenerator;
    private timestampProvider: ITimestampProvider;
    private allTasksResolvers: Array<{ resolve: () => void; reject: (error: Error) => void }> = [];
    private completionCallbacks: TaskCompletionCallback<any, any>[] = [];
    private messageCallbacks: Array<{ messageType: string; callback: TaskMessageCallback<any> }> = [];
    private anyMessageCallbacks: TaskMessageCallback<any>[] = [];
    private tasksQueued: number = 0;
    private tasksPending: number = 0;
    private tasksRunning: number = 0;
    private tasksCompleted: number = 0;
    private tasksFailed: number = 0;
    private taskTimeout: number = 600000; // 10 minutes default
    private taskTimeouts: Map<string, NodeJS.Timeout> = new Map();
    private workerStateChangeCallback: WorkerStateChangeCallback | null = null;
    private workerOptions: IWorkerOptions;
    private isShuttingDown: boolean = false;

    //
    // Creates a new task queue with the specified number of utility process workers
    //
    constructor(workerPath: string, maxWorkers: number, uuidGenerator: IUuidGenerator, timestampProvider: ITimestampProvider, taskTimeout: number, workerOptions: IWorkerOptions) {
        this.workerPath = workerPath;
        this.maxWorkers = maxWorkers;
        this.uuidGenerator = uuidGenerator;
        this.timestampProvider = timestampProvider;
        this.taskTimeout = taskTimeout;
        this.workerOptions = workerOptions;
    }

    //
    // Adds a task to the queue to be executed. Returns the task ID (UUID)
    //
    addTask(type: string, data: any, taskId?: string): string {
        const id = taskId || this.uuidGenerator.generate();

        const task: ITask = {
            id,
            type,
            status: TaskStatus.Pending,
            data,
            createdAt: this.timestampProvider.dateNow(),
        };

        this.tasks.set(id, task);
        this.pendingTasks.push(id);
        this.tasksQueued++;
        this.tasksPending++;

        this.processNextTask();

        return id;
    }

    //
    // Registers a callback that will be invoked whenever any task completes (success or failure)
    //
    onTaskComplete<TInputs = any, TOutputs = any>(callback: TaskCompletionCallback<TInputs, TOutputs>): void {
        this.completionCallbacks.push(callback as TaskCompletionCallback<any, any>);
    }

    //
    // Adds a task and waits for it to complete, returning the outputs. Throws an error if the task fails
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
    // Waits for all pending and running tasks to complete
    //
    async awaitAllTasks(): Promise<void> {
        if (this.tasksPending === 0 && this.tasksRunning === 0) {
            return;
        }

        return new Promise<void>((resolve, reject) => {
            this.allTasksResolvers.push({ resolve, reject });
            this.checkAllTasksComplete();
        });
    }

    //
    // Gets a summary of the queue status: counts of pending, running, completed, and failed tasks
    //
    getStatus(): IQueueStatus {
        return {
            pending: this.tasksPending,
            running: this.tasksRunning,
            completed: this.tasksCompleted,
            failed: this.tasksFailed,
            total: this.tasksQueued,
            peakWorkers: this.peakWorkers,
        };
    }

    //
    // Gets current state of all workers for debugging
    //
    getWorkerState(): IWorkerInfo[] {
        return this.workers.map(worker => {
            const runningTime = worker.taskStartTime
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
    // Sets a callback to be notified when worker state changes
    //
    onWorkerStateChange(callback: WorkerStateChangeCallback): void {
        this.workerStateChangeCallback = callback;
    }

    //
    // Registers a callback that will be called when a task sends messages of the specified type
    //
    onTaskMessage<TMessage = any>(messageType: string, callback: TaskMessageCallback<TMessage>): void {
        this.messageCallbacks.push({ messageType, callback: callback as TaskMessageCallback<any> });
    }

    //
    // Registers a callback that will be called when any task sends a message
    //
    onAnyTaskMessage<TMessage = any>(callback: TaskMessageCallback<TMessage>): void {
        this.anyMessageCallbacks.push(callback as TaskMessageCallback<any>);
    }

    //
    // Notifies the worker state change callback if registered
    //
    private notifyWorkerStateChange(): void {
        if (this.workerStateChangeCallback) {
            this.workerStateChangeCallback(this.getWorkerState());
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

        workerEnv.WORKER_OPTIONS = JSON.stringify(this.workerOptions);

        const worker = utilityProcess.fork(this.workerPath, [], { env: workerEnv });
        const workerState: IWorkerState = {
            worker,
            workerId: this.workers.length + 1,
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
        
        this.notifyWorkerStateChange();
        return workerState;
    }

    //
    // Processes the next pending task by assigning it to an available idle worker
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
        task.startedAt = this.timestampProvider.dateNow();
        this.tasksPending--;
        this.tasksRunning++;
        availableWorker.isIdle = false;
        availableWorker.currentTaskId = taskId;
        availableWorker.currentTaskType = task.type;
        availableWorker.taskStartTime = Date.now();
        this.notifyWorkerStateChange();

        // Set up timeout for this task
        const timeoutId = setTimeout(() => {
            this.handleTaskTimeout(taskId, availableWorker!).catch((error: any) => {
                console.error("Error handling task timeout", error);
            });
        }, this.taskTimeout);
        this.taskTimeouts.set(taskId, timeoutId);

        // Send task to worker
        try {
            availableWorker.worker.postMessage({
                type: "execute",
                taskId: task.id,
                taskType: task.type,
                data: task.data,
            });
        }
        catch (error: any) {
            console.error(`Error sending task to worker ${availableWorker.workerId}`, error);
            const timeout = this.taskTimeouts.get(taskId);
            if (timeout) {
                clearTimeout(timeout);
                this.taskTimeouts.delete(taskId);
            }
            this.handleWorkerCrash(availableWorker);
        }
    }

    //
    // Handles messages from utility process workers (ready, task-completed, task-message)
    //
    private async handleWorkerMessage(workerState: IWorkerState, data: IWorkerResponseMessage): Promise<void> {
        // Handle worker ready message
        if (data && typeof data === "object" && "type" in data && data.type === "worker-ready") {
            workerState.isReady = true;
            workerState.isIdle = true;
            this.notifyWorkerStateChange();
            this.processNextTask(); // Try to process pending tasks now that worker is ready
            return;
        }

        // Handle task result (both success and failure)
        if (data && typeof data === "object" && "type" in data && data.type === "task-completed") {
            const { taskId, result } = data;
            const task = this.tasks.get(taskId);
            if (!task) {
                return;
            }

            // Clear timeout since task completed
            const timeout = this.taskTimeouts.get(taskId);
            if (timeout) {
                clearTimeout(timeout);
                this.taskTimeouts.delete(taskId);
            }

            // Determine if task failed
            const isFailed = result.status === "failed";
            
            // Update task status
            task.status = isFailed ? TaskStatus.Failed : TaskStatus.Completed;
            task.completedAt = this.timestampProvider.dateNow();
            this.tasksRunning--;
            
            // Build result object
            const fullResult: ITaskResult = {
                status: isFailed ? TaskStatus.Failed : TaskStatus.Completed,
                inputs: task.data,
                taskId: task.id,
                taskType: task.type,
                createdAt: task.createdAt,
                startedAt: task.startedAt,
                completedAt: task.completedAt
            };

            if (isFailed) {
                this.tasksFailed++;
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
                this.tasksCompleted++;
                fullResult.outputs = result.outputs;
            }

            // Update worker state
            workerState.isIdle = true;
            workerState.currentTaskId = null;
            workerState.currentTaskType = null;
            workerState.currentTaskRunningTimeMs = null;
            workerState.taskStartTime = null;
            workerState.tasksProcessed++;

            this.notifyWorkerStateChange();
            await this.notifyCompletionCallbacks(fullResult);
            this.checkAllTasksComplete();
            this.tasks.delete(taskId);
            this.processNextTask();
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

        console.error(`[Task Queue] Task ${taskId.substring(0, 2)}${taskId.substring(taskId.length - 2)} timed out after ${this.taskTimeout}ms`);

        // Terminate the worker
        try {
            workerState.worker.kill();
        }
        catch (error: any) {
            console.error(`[Task Queue] Error killing worker ${workerState.workerId}`, error);
        }

        // Mark task as failed immediately
        task.status = TaskStatus.Failed;
        task.completedAt = this.timestampProvider.dateNow();
        this.tasksRunning--;
        this.tasksFailed++;
        const error = new Error("Task timeout");
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

        workerState.isIdle = true;
        workerState.currentTaskId = null;
        workerState.currentTaskType = null;
        workerState.currentTaskRunningTimeMs = null;
        workerState.taskStartTime = null;

        await this.notifyCompletionCallbacks(result);
        this.checkAllTasksComplete();
        this.tasks.delete(taskId);
        this.processNextTask();

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

            const task = this.tasks.get(crashedTaskId);
            if (task && task.status === TaskStatus.Running) {
                // Mark task as failed immediately when worker crashes
                task.status = TaskStatus.Failed;
                task.completedAt = this.timestampProvider.dateNow();
                this.tasksRunning--;
                this.tasksFailed++;
                const error = new Error("Worker crashed");
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

                workerState.currentTaskId = null;
                workerState.currentTaskType = null;
                workerState.currentTaskRunningTimeMs = null;
                workerState.taskStartTime = null;
                this.notifyCompletionCallbacks(result);
                this.checkAllTasksComplete();
                this.tasks.delete(crashedTaskId);
            }
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
            this.notifyWorkerStateChange();
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

        workerEnv.WORKER_OPTIONS = JSON.stringify(this.workerOptions);

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
        this.notifyWorkerStateChange();
    }

    //
    // Invokes all registered completion callbacks with the task result
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
    // Invokes all registered message callbacks with the task message
    //
    private async notifyMessageCallbacks(taskId: string, message: any): Promise<void> {
        const messageType = message.type;

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
    // Checks if all tasks are complete and resolves awaitAllTasks() if so
    // Called after each task completes
    //
    private checkAllTasksComplete(): void {
        if (this.tasksPending === 0 && this.tasksRunning === 0 && this.allTasksResolvers.length > 0) {
            const resolvers = this.allTasksResolvers;
            this.allTasksResolvers = [];
            for (const resolver of resolvers) {
                resolver.resolve();
            }
        }
    }

    //
    // Shuts down the task queue and cleans up resources by terminating all workers
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
        this.tasks.clear();
        this.pendingTasks = [];
        this.messageCallbacks = [];
        this.anyMessageCallbacks = [];
        this.completionCallbacks = [];
    }
}
