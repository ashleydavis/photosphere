import type { PluginListenerHandle } from "@capacitor/core";
import type { ITaskResult, IQueueBackend, WorkerTaskCompletionCallback, TaskMessageCallback, IMessageCallbackEntry, UnsubscribeFn, TaskPriority } from "task-queue";
import { TaskStatus } from "task-queue";
import { JsEngine, type IJsEnginePlugin, type ITaskCompletedEvent, type ITaskCompletedResult } from "./js-engine-plugin";

//
// Capacitor-bridge queue backend for mobile.
// Forwards task dispatch and cancellation to the native `JsEngine` plugin and turns the
// plugin's `taskCompleted` / `taskMessage` events back into IQueueBackend callbacks.
// This mirrors ElectronRendererQueueBackend, which does the same over Electron IPC; the
// renderer/WebView has no workers of its own, so this class is purely a proxy.
//
export class EmbeddedJsQueueBackend implements IQueueBackend {
    //
    // The native JsEngine plugin this backend forwards to.
    //
    private plugin: IJsEnginePlugin;

    //
    // Listener handles returned by the async addListener calls, kept so shutdown can remove them.
    //
    private listenerHandles: PluginListenerHandle[] = [];

    //
    // Callbacks registered for task completion.
    //
    private completionCallbacks: WorkerTaskCompletionCallback[] = [];

    //
    // Callbacks registered for specific task message types.
    //
    private messageCallbacks: IMessageCallbackEntry[] = [];

    //
    // Callbacks registered for all task messages regardless of type.
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
    // Creates a new backend bridging to the native JsEngine plugin.
    // The plugin is injectable so tests can supply a mock.
    //
    constructor(plugin: IJsEnginePlugin = JsEngine) {
        this.plugin = plugin;
    }

    //
    // Registers the native event listeners. Must be awaited during app bootstrap before
    // any task is dispatched, because Capacitor addListener is async. The native plugin
    // additionally buffers events per-taskId until a listener is registered, closing the
    // race if a task were ever dispatched during startup.
    //
    async init(): Promise<void> {
        const completedHandle = await this.plugin.addListener("taskCompleted", event => {
            this.handleTaskCompleted(event);
        });
        const messageHandle = await this.plugin.addListener("taskMessage", event => {
            this.notifyMessageCallbacks(event.taskId, event.message);
        });
        this.listenerHandles.push(completedHandle, messageHandle);
    }

    //
    // Fire-and-forget task dispatch, exactly like the Electron send path. The taskId is
    // generated locally and returned synchronously; the bridge call is not awaited. If the
    // bridge call itself rejects (plugin not registered, marshalling failure) a synthetic
    // taskCompleted error result is emitted so the task fails loudly through the normal
    // completion path rather than hanging forever.
    //
    addTask(type: string, data: any, source: string, taskId?: string, priority?: TaskPriority): string {
        const id = taskId ?? crypto.randomUUID();

        this.plugin.addTask({ taskId: id, type, data, source, priority })
            .catch(error => {
                const result: ITaskResult = {
                    taskId: id,
                    status: TaskStatus.Failed,
                    error: error instanceof Error ? error : new Error(String(error)),
                    errorMessage: error?.message ?? String(error),
                    type,
                    inputs: data,
                };
                this.notifyCompletionCallbacks(result);
            });

        const callbacks = this.taskAddedCallbacks.get(source);
        if (callbacks) {
            for (const callback of callbacks) {
                callback(id);
            }
        }

        return id;
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
    // Registers a callback that fires whenever any task completes (success or failure).
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
    // Registers a callback for task messages of a specific type.
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
    // Registers a callback for all task messages regardless of type.
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
    // Forwards a cancel-by-source request to the native plugin and, only once the bridge
    // confirms the cancellation, fires local cancellation callbacks. Awaits and propagates
    // the bridge rejection (matching cancelMobileTasks and the defensive addTask path) so a
    // failed cancel does not falsely clear the Job Manager while the native engine keeps running.
    //
    async cancelTasks(source: string): Promise<void> {
        await this.plugin.cancelTasks({ source });
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
    // Removes the native listener handles and tears down the engine pool. The Capacitor
    // equivalent of Electron's removeAllListeners is handle.remove() per stored handle.
    // Awaits and propagates the bridge rejection rather than swallowing it to console.error,
    // so a failed teardown surfaces instead of silently reporting success on a device.
    //
    async shutdown(): Promise<void> {
        for (const handle of this.listenerHandles) {
            void handle.remove();
        }
        this.listenerHandles = [];
        await this.plugin.shutdown();
    }

    //
    // Turns a native taskCompleted event into an ITaskResult and notifies completion callbacks.
    //
    private handleTaskCompleted(event: ITaskCompletedEvent): void {
        this.notifyCompletionCallbacks(this.toTaskResult(event.result));
    }

    //
    // Reconstructs a full ITaskResult (including an Error object when failed) from the
    // JSON-safe result payload the native plugin sends.
    //
    private toTaskResult(result: ITaskCompletedResult): ITaskResult {
        return {
            taskId: result.taskId,
            status: result.status,
            error: result.status === TaskStatus.Failed
                ? new Error(result.errorMessage ?? "Unknown error")
                : undefined,
            errorMessage: result.errorMessage,
            outputs: result.outputs,
            type: result.type,
            inputs: result.inputs,
        };
    }

    //
    // Invokes all registered completion callbacks.
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
    // Invokes message callbacks matching the message type, plus the any-message callbacks.
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
            catch (error: any) {
                console.error("Error in any task message callback:", error);
            }
        }
    }
}
