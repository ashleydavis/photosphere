//
// Mock queue backend for testing TaskQueue.
// Executes tasks inline (in-process) for fast, predictable tests.
//

import type { ITaskResult, WorkerTaskCompletionCallback, TaskMessageCallback, IMessageCallbackEntry, UnsubscribeFn } from "../src/lib/types";
import type { IQueueBackend } from "../src/lib/queue-backend";
import { TaskStatus } from "../src/lib/types";
import type { ITaskContext } from "../src/lib/types";
import { executeTaskHandler } from "../src/lib/worker";
import { TestUuidGenerator, TestTimestampProvider } from "node-utils";

//
// Mock implementation of IQueueBackend that executes tasks inline.
// Supports concurrency limits for testing parallel-execution scenarios.
//
export class MockWorkerPool implements IQueueBackend {
    private completionCallbacks: WorkerTaskCompletionCallback[] = [];
    private messageCallbacks: IMessageCallbackEntry[] = [];
    private anyMessageCallbacks: TaskMessageCallback[] = [];
    private taskAddedCallbacks: Map<string, ((taskId: string) => void)[]> = new Map();
    private tasksCancelledCallbacks: Map<string, (() => void)[]> = new Map();
    private activeTaskCount: number = 0;
    private pendingTasks: { id: string; type: string; data: any; source: string }[] = [];
    private maxConcurrent: number;
    private cancelledSources: Set<string> = new Set();
    private baseContext: Omit<ITaskContext, "sendMessage" | "isCancelled" | "taskId">;

    constructor(maxConcurrent: number = 2, baseContext?: Partial<Omit<ITaskContext, "sendMessage" | "isCancelled" | "taskId">>) {
        this.maxConcurrent = maxConcurrent;
        this.baseContext = {
            uuidGenerator: baseContext?.uuidGenerator || new TestUuidGenerator(),
            timestampProvider: baseContext?.timestampProvider || new TestTimestampProvider(),
            sessionId: baseContext?.sessionId || "test-session",
        };
    }

    addTask(type: string, data: any, source: string, taskId?: string): string {
        const id = taskId ?? `${type}-${Date.now()}-${Math.random()}`;
        const cbs = this.taskAddedCallbacks.get(source);
        if (cbs) {
            for (const cb of cbs) {
                cb(id);
            }
        }
        this.pendingTasks.push({ id, type, data, source });
        this.tryDispatch();
        return id;
    }

    private tryDispatch(): void {
        while (this.activeTaskCount < this.maxConcurrent && this.pendingTasks.length > 0) {
            const task = this.pendingTasks.shift()!;
            this.activeTaskCount++;
            this.executeTask(task).catch((error) => {
                console.error(`Error executing task ${task.id}:`, error);
            });
        }
    }

    private async executeTask(task: { id: string; type: string; data: any; source: string }): Promise<void> {
        try {
            const taskSpecificSendMessage = (message: any): void => {
                this.notifyMessageCallbacks(task.id, message);
            };

            const taskContext: ITaskContext = {
                ...this.baseContext,
                sendMessage: taskSpecificSendMessage,
                isCancelled: (): boolean => this.cancelledSources.has(task.source),
                taskId: task.id,
            };

            const outputs = await executeTaskHandler(task.type, task.data, taskContext);

            const result: ITaskResult = {
                taskId: task.id,
                type: task.type,
                inputs: task.data,
                status: TaskStatus.Succeeded,
                outputs,
            };

            this.activeTaskCount--;
            await this.notifyCompletionCallbacks(result);
            this.tryDispatch();
        }
        catch (error: any) {
            const err = error instanceof Error ? error : new Error(String(error));
            const result: ITaskResult = {
                taskId: task.id,
                type: task.type,
                inputs: task.data,
                status: TaskStatus.Failed,
                error: err,
                errorMessage: err.message || "Unknown error",
            };

            this.activeTaskCount--;
            await this.notifyCompletionCallbacks(result);
            this.tryDispatch();
        }
    }

    onTaskAdded(source: string, callback: (taskId: string) => void): UnsubscribeFn {
        const existing = this.taskAddedCallbacks.get(source) ?? [];
        existing.push(callback);
        this.taskAddedCallbacks.set(source, existing);
        return () => {
            const callbacks = this.taskAddedCallbacks.get(source);
            if (callbacks) {
                const index = callbacks.indexOf(callback);
                if (index !== -1) {
                    callbacks.splice(index, 1);
                }
            }
        };
    }

    onTaskComplete(callback: WorkerTaskCompletionCallback): UnsubscribeFn {
        this.completionCallbacks.push(callback);
        return () => {
            const index = this.completionCallbacks.indexOf(callback);
            if (index !== -1) {
                this.completionCallbacks.splice(index, 1);
            }
        };
    }

    onTaskMessage(messageType: string, callback: TaskMessageCallback): UnsubscribeFn {
        const entry = { messageType, callback };
        this.messageCallbacks.push(entry);
        return () => {
            const index = this.messageCallbacks.indexOf(entry);
            if (index !== -1) {
                this.messageCallbacks.splice(index, 1);
            }
        };
    }

    onAnyTaskMessage(callback: TaskMessageCallback): UnsubscribeFn {
        this.anyMessageCallbacks.push(callback);
        return () => {
            const index = this.anyMessageCallbacks.indexOf(callback);
            if (index !== -1) {
                this.anyMessageCallbacks.splice(index, 1);
            }
        };
    }

    cancelTasks(source: string): void {
        this.cancelledSources.add(source);
        this.pendingTasks = this.pendingTasks.filter(task => task.source !== source);
        const callbacks = this.tasksCancelledCallbacks.get(source);
        if (callbacks) {
            for (const cb of callbacks) {
                cb();
            }
        }
    }

    onTasksCancelled(source: string, callback: () => void): UnsubscribeFn {
        const existing = this.tasksCancelledCallbacks.get(source) ?? [];
        existing.push(callback);
        this.tasksCancelledCallbacks.set(source, existing);
        return () => {
            const cbs = this.tasksCancelledCallbacks.get(source);
            if (cbs) {
                const idx = cbs.indexOf(callback);
                if (idx !== -1) {
                    cbs.splice(idx, 1);
                }
            }
        };
    }

    shutdown(): void {
        this.pendingTasks = [];
        this.completionCallbacks = [];
        this.messageCallbacks = [];
        this.anyMessageCallbacks = [];
        this.taskAddedCallbacks.clear();
        this.tasksCancelledCallbacks.clear();
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

        for (const callback of this.anyMessageCallbacks) {
            try {
                callback({ taskId, message });
            }
            catch (error: any) {
                console.error("Error in any task message callback:", error);
            }
        }
    }
}
