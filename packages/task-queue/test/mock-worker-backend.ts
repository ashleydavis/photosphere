//
// Mock worker backend for testing TaskQueue
// Executes tasks synchronously/inline for fast, predictable tests
//

import type { ITask, ITaskResult, IWorkerBackend, WorkerTaskCompletionCallback, TaskMessageCallback } from "../src/lib/worker-backend";
import { TaskStatus } from "../src/lib/worker-backend";
import type { ITaskContext } from "../src/lib/types";
import { executeTaskHandler } from "../src/lib/worker";
import { TestUuidGenerator, TestTimestampProvider } from "node-utils";

export class MockWorkerBackend implements IWorkerBackend {
    private completionCallbacks: WorkerTaskCompletionCallback[] = [];
    private messageCallbacks: Array<{ messageType: string; callback: TaskMessageCallback }> = [];
    private anyMessageCallbacks: TaskMessageCallback[] = [];
    private workerAvailableCallbacks: (() => void)[] = [];
    private activeTasks: Map<string, ITask<any>> = new Map();
    private maxConcurrent: number;
    private baseContext: Omit<ITaskContext, "sendMessage">;

    constructor(maxConcurrent: number = 2, baseContext?: Partial<Omit<ITaskContext, "sendMessage">>) {
        this.maxConcurrent = maxConcurrent;
        this.baseContext = {
            uuidGenerator: baseContext?.uuidGenerator || new TestUuidGenerator(),
            timestampProvider: baseContext?.timestampProvider || new TestTimestampProvider(),
            sessionId: baseContext?.sessionId || "test-session",
        };
    }

    dispatchTask(task: ITask<any>): boolean {
        if (this.activeTasks.size >= this.maxConcurrent) {
            return false;
        }

        this.activeTasks.set(task.id, task);
        
        // Execute task asynchronously
        this.executeTask(task).catch((error) => {
            console.error(`Error executing task ${task.id}:`, error);
        });

        return true;
    }

    private async executeTask(task: ITask<any>): Promise<void> {
        try {
            // Create a task-specific sendMessage function
            const taskSpecificSendMessage = (message: any): void => {
                this.notifyMessageCallbacks(task.id, message);
            };

            // Create task context
            const taskContext = {
                ...this.baseContext,
                sendMessage: taskSpecificSendMessage,
            };

            const outputs = await executeTaskHandler(task.type, task.data, taskContext);

            // Task completed successfully
            const result: ITaskResult = {
                taskId: task.id,
                status: TaskStatus.Succeeded,
                outputs,
            };

            this.activeTasks.delete(task.id);
            await this.notifyCompletionCallbacks(result);
            this.notifyWorkerAvailable();
        }
        catch (error: any) {
            // Task failed
            const err = error instanceof Error ? error : new Error(String(error));
            const result: ITaskResult = {
                taskId: task.id,
                status: TaskStatus.Failed,
                error: err,
                errorMessage: err.message || "Unknown error",
            };

            this.activeTasks.delete(task.id);
            await this.notifyCompletionCallbacks(result);
            this.notifyWorkerAvailable();
        }
    }

    onWorkerAvailable(callback: () => void): void {
        this.workerAvailableCallbacks.push(callback);
        // Immediately notify that a worker is available
        callback();
    }

    onTaskComplete(callback: WorkerTaskCompletionCallback): void {
        this.completionCallbacks.push(callback);
    }

    onTaskMessage(messageType: string, callback: TaskMessageCallback): void {
        this.messageCallbacks.push({ messageType, callback });
    }

    onAnyTaskMessage(callback: TaskMessageCallback): void {
        this.anyMessageCallbacks.push(callback);
    }

    isIdle(): boolean {
        return this.activeTasks.size === 0;
    }

    shutdown(): void {
        this.activeTasks.clear();
        this.completionCallbacks = [];
        this.messageCallbacks = [];
        this.anyMessageCallbacks = [];
        this.workerAvailableCallbacks = [];
    }

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

    private notifyMessageCallbacks(taskId: string, message: any): void {
        const messageType = message && typeof message === "object" && "type" in message ? message.type : undefined;

        // Notify callbacks registered for specific message types
        for (const { messageType: filterType, callback } of this.messageCallbacks) {
            if (messageType !== filterType) {
                continue;
            }

            try {
                callback({ taskId, message });
            }
            catch (error: any) {
                console.error("Error in task message callback:", error);
            }
        }

        // Notify callbacks registered for any message type
        for (const callback of this.anyMessageCallbacks) {
            try {
                callback({ taskId, message });
            }
            catch (error: any) {
                console.error("Error in any task message callback:", error);
            }
        }
    }

    private notifyWorkerAvailable(): void {
        for (const callback of this.workerAvailableCallbacks) {
            callback();
        }
    }
}

