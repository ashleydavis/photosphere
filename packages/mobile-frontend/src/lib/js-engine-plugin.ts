import { registerPlugin, type PluginListenerHandle } from "@capacitor/core";
import type { TaskStatus } from "task-queue";

//
// Options for dispatching a single task into the native embedded-engine pool.
// Mirrors the Electron `add-task` IPC payload but crosses the Capacitor bridge.
//
export interface IAddTaskOptions {
    //
    // Locally-generated task id (the backend owns id generation, like the Electron path).
    //
    taskId: string;

    //
    // The handler type name used to look up the registered handler in the engine.
    //
    type: string;

    //
    // Input data for the handler. Capacitor serialises this across the bridge.
    //
    data: any;

    //
    // Source tag grouping related tasks so they can be cancelled together.
    //
    source: string;
}

//
// Options for cancelling every task that shares a given source.
//
export interface ICancelTasksOptions {
    //
    // The source tag whose tasks (pending and running) should be cancelled.
    //
    source: string;
}

//
// Result payload carried by a `taskCompleted` event. This is the JSON-safe subset
// of ITaskResult: native cannot marshal a live Error object across the bridge, so it
// sends `errorMessage` and the backend reconstructs an Error for the result.
//
export interface ITaskCompletedResult {
    //
    // The id of the task that produced this result.
    //
    taskId: string;

    //
    // Whether the task succeeded or failed.
    //
    status: TaskStatus;

    //
    // Human-readable error message when the task failed.
    //
    errorMessage?: string;

    //
    // The handler output data when the task succeeded.
    //
    outputs?: any;

    //
    // The type of the task that produced this result.
    //
    type: string;

    //
    // The input data the task was queued with.
    //
    inputs: any;
}

//
// Payload for the `taskCompleted` event emitted by the native plugin.
//
export interface ITaskCompletedEvent {
    //
    // The id of the completed task.
    //
    taskId: string;

    //
    // The completion result for the task.
    //
    result: ITaskCompletedResult;
}

//
// Payload for the `taskMessage` event emitted by the native plugin when a running
// handler streams a progress message via `context.sendMessage`.
//
export interface ITaskMessageEvent {
    //
    // The id of the task that sent the message.
    //
    taskId: string;

    //
    // The streamed message payload.
    //
    message: any;
}

//
// The `JsEngine` Capacitor plugin interface. The native implementation (Swift on iOS,
// Java/QuickJS on Android) owns the engine pool, dispatcher, running-task map, the
// cancelled-source set, and the single sessionId, and emits the two listener events.
//
export interface IJsEnginePlugin {
    //
    // Dispatches a task into the engine pool. Fire-and-forget from the backend: the id
    // is generated locally and the returned Promise is not awaited for the result.
    //
    addTask(options: IAddTaskOptions): Promise<void>;

    //
    // Cancels every task (pending and running) that shares the given source.
    //
    cancelTasks(options: ICancelTasksOptions): Promise<void>;

    //
    // Tears down the engine pool and releases native resources.
    //
    shutdown(): Promise<void>;

    //
    // Registers a listener for the `taskCompleted` event.
    //
    addListener(eventName: "taskCompleted", listenerFunc: (event: ITaskCompletedEvent) => void): Promise<PluginListenerHandle>;

    //
    // Registers a listener for the `taskMessage` event.
    //
    addListener(eventName: "taskMessage", listenerFunc: (event: ITaskMessageEvent) => void): Promise<PluginListenerHandle>;
}

//
// The registered `JsEngine` plugin singleton. On a device this is backed by the native
// plugin; in the WebView dev/browser environment it is a Capacitor web proxy.
//
export const JsEngine = registerPlugin<IJsEnginePlugin>("JsEngine");
