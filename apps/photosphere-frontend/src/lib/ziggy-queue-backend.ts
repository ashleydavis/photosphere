import type { ITaskResult, IQueueBackend, WorkerTaskCompletionCallback, TaskMessageCallback, IMessageCallbackEntry, UnsubscribeFn, TaskPriority } from "task-queue";
import type { IAddTask, IJsonValue, ITaskCompletedEvent, ITaskEvent, IZiggyBridge } from "ziggy";

//
// Ziggy bridge-based queue backend.
// Forwards task dispatch and completion to the core over window.ziggy.
// The page has no workers of its own: this class is purely a proxy.
//
export class ZiggyQueueBackend implements IQueueBackend {
    //
    // The bridge the native app injects into the page.
    //
    private ziggy: IZiggyBridge;

    //
    // Callbacks registered for task completion.
    //
    private completionCallbacks: WorkerTaskCompletionCallback[] = [];

    //
    // Callbacks registered for specific task event types.
    //
    private messageCallbacks: IMessageCallbackEntry[] = [];

    //
    // Callbacks registered for all task events regardless of type.
    //
    private anyMessageCallbacks: TaskMessageCallback[] = [];

    //
    // Per-source callbacks fired when a task is added via addTask.
    //
    private taskAddedCallbacks: Map<string, ((taskId: string) => void)[]> = new Map();

    //
    // Per-source callbacks fired when cancelTasks is called for that source.
    //
    private tasksCancelledCallbacks: Map<string, (() => void)[]> = new Map();

    //
    // The listener this registers for Ziggy's task-completed events, kept so shutdown can remove it.
    //
    private readonly taskCompletedListener = (data: ITaskCompletedEvent): void => {
        this.handleTaskCompleted(data);
    };

    //
    // The listener this registers for Ziggy's task-event events, kept so shutdown can remove it.
    //
    private readonly taskEventListener = (data: ITaskEvent<IJsonValue>): void => {
        this.notifyEventCallbacks(data.taskId, data.data);
    };

    //
    // Creates a new backend that communicates with the core over the bridge.
    //
    constructor(ziggy: IZiggyBridge) {
        this.ziggy = ziggy;
        this.setupMessageHandlers();
    }

    //
    // Sets up bridge listeners for task completion and task events.
    //
    private setupMessageHandlers(): void {
        this.ziggy.onTaskCompleted(this.taskCompletedListener);
        this.ziggy.onTaskEvent<IJsonValue>(this.taskEventListener);
    }

    //
    // Registers a callback that fires whenever any task completes.
    //
    onTaskComplete(callback: WorkerTaskCompletionCallback): UnsubscribeFn {
        this.completionCallbacks.push(callback);
        return () => {
            const index = this.completionCallbacks.indexOf(callback);
            if (index !== -1) {
                this.completionCallbacks.splice(index, 1);
            }
        };
    }

    //
    // Registers a callback for task events of a specific type.
    //
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

    //
    // Registers a callback for all task events regardless of type.
    //
    onAnyTaskMessage(callback: TaskMessageCallback): UnsubscribeFn {
        this.anyMessageCallbacks.push(callback);
        return () => {
            const index = this.anyMessageCallbacks.indexOf(callback);
            if (index !== -1) {
                this.anyMessageCallbacks.splice(index, 1);
            }
        };
    }

    //
    // Registers a callback fired when a task with the given source is added.
    //
    onTaskAdded(source: string, callback: (taskId: string) => void): UnsubscribeFn {
        const existing = this.taskAddedCallbacks.get(source);
        if (existing) {
            existing.push(callback);
        }
        else {
            this.taskAddedCallbacks.set(source, [callback]);
        }
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

    //
    // Forwards a task to the core and fires onTaskAdded callbacks. The priority is sent as its text,
    // "interactive" or "background", and left out when the task has none, which the core runs as background.
    //
    addTask(type: string, data: IJsonValue, source: string, taskId?: string, priority?: TaskPriority): string {
        const id = taskId ?? crypto.randomUUID();
        const task: IAddTask = {
            taskType: type,
            data,
            source,
            taskId: id,
        };
        if (priority !== undefined) {
            task.priority = priority;
        }
        this.ziggy.addTask(task);
        const callbacks = this.taskAddedCallbacks.get(source);
        if (callbacks) {
            for (const callback of callbacks) {
                callback(id);
            }
        }
        return id;
    }

    //
    // Forwards the cancel signal to the core and fires local cancellation callbacks.
    //
    // Sent as the cancel-tasks main-command rather than on Ziggy's own cancelTasks, which cancels in the core's runner alone:
    // a task still waiting for a worker is dropped there without a word, so a task queue in the core that counted it (an import
    // waiting on its children) waited for it for good. The main-command cancels through the core's queue backend, which also tells
    // those task queues that their source was cancelled. Found by 33-import-cancel in the Release Zig workflow's desktop smoke tests on
    // ubuntu-latest, where the cancelled import held a worker for good and the import after it timed out waiting for "1 assets imported".
    //
    cancelTasks(source: string): void {
        this.ziggy.send('main-command', {
            command: 'cancel-tasks',
            source,
        });
        const callbacks = this.tasksCancelledCallbacks.get(source);
        if (callbacks) {
            for (const callback of callbacks) {
                callback();
            }
        }
    }

    //
    // Registers a callback that fires when cancelTasks is called for the given source.
    //
    onTasksCancelled(source: string, callback: () => void): UnsubscribeFn {
        const existing = this.tasksCancelledCallbacks.get(source) ?? [];
        existing.push(callback);
        this.tasksCancelledCallbacks.set(source, existing);
        return () => {
            const callbacks = this.tasksCancelledCallbacks.get(source);
            if (callbacks) {
                const index = callbacks.indexOf(callback);
                if (index !== -1) {
                    callbacks.splice(index, 1);
                }
            }
        };
    }

    //
    // Handles a task-completed event from the core.
    //
    private handleTaskCompleted(data: ITaskCompletedEvent): void {
        this.notifyCompletionCallbacks(data.result as ITaskResult);
    }

    //
    // Invokes all registered completion callbacks.
    //
    private async notifyCompletionCallbacks(result: ITaskResult): Promise<void> {
        for (const callback of this.completionCallbacks) {
            try {
                await callback(result);
            }
            catch (error) {
                console.error("Error in task completion callback:", error);
            }
        }
    }

    //
    // Invokes the callbacks matching the task event's type.
    //
    private async notifyEventCallbacks(taskId: string, event: IJsonValue): Promise<void> {
        const eventType = taskEventType(event);

        for (const { messageType: filterType, callback } of this.messageCallbacks) {
            if (eventType !== filterType) {
                continue;
            }

            try {
                await callback({ taskId, message: event });
            }
            catch (error) {
                console.error("Error in task event callback:", error);
            }
        }

        for (const callback of this.anyMessageCallbacks) {
            try {
                await callback({ taskId, message: event });
            }
            catch (error) {
                console.error("Error in any task event callback:", error);
            }
        }
    }

    //
    // Removes all bridge listeners. Call when the queue is no longer needed.
    //
    shutdown(): void {
        this.ziggy.removeTaskCompletedListener(this.taskCompletedListener);
        this.ziggy.removeTaskEventListener<IJsonValue>(this.taskEventListener);
    }
}

//
// The type a task event declares in its "type" field, or undefined for one that is not an object or has no such field.
//
function taskEventType(event: IJsonValue): IJsonValue | undefined {
    if (event === null || typeof event !== "object" || Array.isArray(event)) {
        return undefined;
    }
    return event.type;
}
