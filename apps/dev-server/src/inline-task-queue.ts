import type { ITaskQueue, IQueueStatus, IWorkerInfo } from "task-queue";
import { TaskStatus, type ITaskResult, type TaskCompletionCallback, type WorkerStateChangeCallback, type TaskMessageCallback } from "task-queue";
import { executeTaskHandler } from "task-queue/src/lib/worker";
import type { ITaskContext } from "task-queue";
import type { IUuidGenerator, ITimestampProvider } from "utils";
import { initTaskHandlers } from "api";
import { RandomUuidGenerator, TimestampProvider } from "utils";
import { join } from "node:path";
import { tmpdir } from "node:os";

interface IMessageCallback {
    messageType: string;
    callback: TaskMessageCallback<any>;
}

interface ITaskExecutionContext {
    taskId: string;
}

interface IBaseTaskContext {
    uuidGenerator: IUuidGenerator;
    timestampProvider: ITimestampProvider;
    sessionId: string;
}

//
// Inline task queue that executes tasks directly without workers
// Supports up to maxConcurrent tasks running at once
//
export class InlineTaskQueue implements ITaskQueue {
    private tasks: Map<string, ITask> = new Map();
    private pendingTasks: string[] = [];
    private runningTasks: Set<string> = new Set();
    private completionCallbacks: TaskCompletionCallback<any, any>[] = [];
    private messageCallbacks: IMessageCallback[] = [];
    private tasksQueued: number = 0;
    private tasksCompleted: number = 0;
    private tasksFailed: number = 0;
    private maxConcurrent: number;
    private baseWorkingDirectory: string;
    private uuidGenerator: RandomUuidGenerator;
    private baseContext: IBaseTaskContext;
    private workerStateChangeCallback: WorkerStateChangeCallback | null = null;
    private taskContexts: Map<string, ITaskExecutionContext> = new Map();

    constructor(maxConcurrent: number, baseWorkingDirectory: string, uuidGenerator: RandomUuidGenerator, workerOptions: { verbose?: boolean; sessionId?: string }) {
        this.maxConcurrent = maxConcurrent;
        this.baseWorkingDirectory = baseWorkingDirectory;
        this.uuidGenerator = uuidGenerator;
        
        // Initialize task handlers
        initTaskHandlers();
        
        // Create base worker context (without sendMessage - that will be task-specific)
        // Note: We create our own context here instead of using initWorkerContext
        // because initWorkerContext sets up worker-specific logging which we don't need
        const timestampProvider = new TimestampProvider();
        const sessionId = workerOptions.sessionId || this.uuidGenerator.generate();
        this.baseContext = {
            uuidGenerator: this.uuidGenerator,
            timestampProvider,
            sessionId,
        };
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
            createdAt: new Date(),
            timeoutCount: 0
        };

        this.tasks.set(id, task);
        this.pendingTasks.push(id);
        this.tasksQueued++;
        console.log(`[TaskQueue] Task added: ${id} (type: ${type})`);
        this.processNextTask();

        return id;
    }

    onTaskComplete<TInputs = any, TOutputs = any>(callback: TaskCompletionCallback<TInputs, TOutputs>): void {
        this.completionCallbacks.push(callback as TaskCompletionCallback<any, any>);
    }

    async awaitAllTasks(): Promise<void> {
        while (this.pendingTasks.length > 0 || this.runningTasks.size > 0) {
            await new Promise<void>((resolve) => setTimeout(resolve, 100));
        }
    }

    getStatus(): IQueueStatus {
        return {
            pending: this.pendingTasks.length,
            running: this.runningTasks.size,
            completed: this.tasksCompleted,
            failed: this.tasksFailed,
            total: this.tasks.size + this.tasksCompleted + this.tasksFailed,
            tasksQueued: this.tasksQueued,
            peakWorkers: this.maxConcurrent
        };
    }

    getWorkerState(): IWorkerInfo[] {
        // Return fake worker info for compatibility
        return Array.from({ length: this.maxConcurrent }, (_, i) => ({
            workerId: i + 1,
            isReady: true,
            isIdle: this.runningTasks.size <= i,
            currentTaskId: null, // We don't track which task is on which "worker"
            currentTaskType: null,
            currentTaskRunningTimeMs: null,
            tasksProcessed: 0,
        }));
    }

    onWorkerStateChange(callback: WorkerStateChangeCallback): void {
        this.workerStateChangeCallback = callback;
    }

    onTaskMessage<TMessage = any>(messageType: string, callback: TaskMessageCallback<TMessage>): void {
        this.messageCallbacks.push({ messageType, callback: callback as TaskMessageCallback<any> });
    }

    shutdown(): void {
        // Nothing to shut down for inline execution
    }

    private async processNextTask(): Promise<void> {
        if (this.pendingTasks.length === 0) {
            return;
        }

        if (this.runningTasks.size >= this.maxConcurrent) {
            return;
        }

        const taskId = this.pendingTasks.shift()!;
        const task = this.tasks.get(taskId);
        if (!task) {
            return;
        }

        // Mark task as running
        task.status = TaskStatus.Running;
        task.startedAt = new Date();
        this.runningTasks.add(taskId);
        console.log(`[TaskQueue] Task started: ${taskId} (type: ${task.type})`);

        // Execute task inline
        this.executeTask(task).catch((error) => {
            console.error(`Error executing task ${taskId}:`, error);
        });
    }

    private async executeTask(task: ITask): Promise<void> {
        try {
            // Create a task-specific context for this execution
            const taskContext = { taskId: task.id };
            this.taskContexts.set(task.id, taskContext);

            // Create a task-specific sendMessage function that captures the task ID in a closure
            // This ensures each concurrent task routes messages correctly without race conditions
            const taskSpecificSendMessage = (message: any): void => {
                this.notifyMessageCallbacks(task.id, message).catch((error) => {
                    console.error("Error notifying message callbacks:", error);
                });
            };

            // Create a task-specific context with the task-specific sendMessage
            const taskContextWithSendMessage: ITaskContext = {
                ...this.baseContext,
                sendMessage: taskSpecificSendMessage,
            };

            const outputs = await executeTaskHandler(task.type, task.data, task.workingDirectory, taskContextWithSendMessage);

            // Clean up task context
            this.taskContexts.delete(task.id);

            // Task completed successfully
            task.status = TaskStatus.Completed;
            task.completedAt = new Date();
            const result: ITaskResult = {
                status: TaskStatus.Completed,
                message: typeof outputs === "string" ? outputs : "Task completed successfully",
                outputs,
                inputs: task.data,
                taskId: task.id,
                taskType: task.type,
                createdAt: task.createdAt,
                startedAt: task.startedAt,
                completedAt: task.completedAt
            };
            task.result = result;

            this.tasksCompleted++;
            this.runningTasks.delete(task.id);
            const duration = task.completedAt.getTime() - (task.startedAt?.getTime() || task.createdAt.getTime());
            console.log(`[TaskQueue] Task completed: ${task.id} (type: ${task.type}, duration: ${duration}ms)`);
            await this.notifyCompletionCallbacks(result);
            this.tasks.delete(task.id);

            // Process next task
            this.processNextTask();
        }
        catch (error: unknown) {
            // Clear task context on error
            this.taskContexts.delete(task.id);

            // Task failed
            task.status = TaskStatus.Failed;
            task.completedAt = new Date();
            const err = error instanceof Error ? error : new Error(String(error));
            const result: ITaskResult = {
                status: TaskStatus.Failed,
                error: err,
                errorMessage: err.message || "Unknown error",
                inputs: task.data,
                taskId: task.id,
                taskType: task.type,
                createdAt: task.createdAt,
                startedAt: task.startedAt,
                completedAt: task.completedAt
            };
            task.result = result;

            this.tasksFailed++;
            this.runningTasks.delete(task.id);
            const duration = task.completedAt.getTime() - (task.startedAt?.getTime() || task.createdAt.getTime());
            console.log(`[TaskQueue] Task failed: ${task.id} (type: ${task.type}, duration: ${duration}ms, error: ${err.message})`);
            await this.notifyCompletionCallbacks(result);
            this.tasks.delete(task.id);

            // Process next task
            this.processNextTask();
        }
    }

    private async notifyCompletionCallbacks(result: ITaskResult): Promise<void> {
        for (const callback of this.completionCallbacks) {
            try {
                await callback(result);
            }
            catch (error: unknown) {
                console.error("Error in task completion callback:", error);
            }
        }
    }

    private async notifyMessageCallbacks(taskId: string, message: any): Promise<void> {
        const messageType = message && typeof message === "object" && "type" in message ? message.type : undefined;
        
        for (const { messageType: filterType, callback } of this.messageCallbacks) {
            // If a filter type is specified, only invoke if it matches
            if (filterType && messageType !== filterType) {
                continue;
            }
            
            try {
                await callback(taskId, message);
            }
            catch (error: unknown) {
                console.error("Error in task message callback:", error);
            }
        }
    }

}

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
    timeoutCount: number;
}

