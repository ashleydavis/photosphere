import { registerPlugin, type PluginListenerHandle } from "@capacitor/core";
import type { TaskStatus, TaskPriority } from "task-queue";

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

    //
    // How urgent the task is, which decides where the native pool puts it in the pending queue.
    // Absent means the pool decides: at its parent's priority when a running task queued it, and at
    // the default otherwise.
    //
    priority?: TaskPriority;
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
// Options for opening the native photo picker.
//
export interface IPickFilesOptions {
    //
    // The picker dialog title (advisory; some platforms ignore it).
    //
    title: string;
}

//
// Result of a native photo pick. The picker copies each chosen item into the app sandbox and
// returns its sandbox-relative path, so the import task can read it through the fs host functions.
//
export interface IPickFilesResult {
    //
    // Sandbox-relative paths of the copied picked files (empty when the user cancelled).
    //
    paths: string[];
}

//
// Options for handing a single finished file out of the app via the native share/save sheet.
//
export interface IExportFileOptions {
    //
    // Sandbox-relative path of the finished file to export. The download task has already written
    // the bytes here; the plugin presents the sheet for this file and deletes it on every exit.
    //
    path: string;

    //
    // Test-only outcome. When set, the plugin skips presenting the (non-automatable) sheet and runs
    // its completion handler with this outcome, so a smoke test on a device drives the shared and
    // cancelled paths (including the temp-file cleanup) without a sheet that cannot be dismissed.
    // Undefined in production so the real sheet is presented.
    //
    testOutcome?: "shared" | "cancelled";
}

//
// Result of a single-file export. `path` is the exported sandbox-relative path on success, or null
// when the user cancelled the sheet (the frontend maps null to the "cancelled" undefined contract).
//
export interface IExportFileResult {
    //
    // The exported sandbox-relative path, or null when the user cancelled.
    //
    path: string | null;
}

//
// Options for handing several finished files out of the app via a single native sheet.
//
export interface IExportFilesOptions {
    //
    // Sandbox-relative paths of the finished files to export. Each is deleted on every sheet exit.
    //
    paths: string[];

    //
    // Test-only outcome; see IExportFileOptions.testOutcome. Undefined in production.
    //
    testOutcome?: "shared" | "cancelled";
}

//
// Result of a multi-file export. `paths` is the exported sandbox-relative paths on success, or null
// when the user cancelled the sheet.
//
export interface IExportFilesResult {
    //
    // The exported sandbox-relative paths, or null when the user cancelled.
    //
    paths: string[] | null;
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
//
// What the platform said when asked for the photo library permission.
//
export interface IMediaPermissionResult {
    // Whether the user granted it.
    granted: boolean;
}

//
// What to stage as the answer to the next photo library delete request.
//
export interface IStageMediaDeleteOptions {
    // "deleted" when the user is taken to have confirmed, "cancelled" when they declined.
    outcome: "deleted" | "cancelled";
}

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
    // Opens the native multi-select photo picker, copies each chosen item into the app sandbox, and
    // resolves with their sandbox-relative paths (empty when cancelled).
    //
    pickFiles(options: IPickFilesOptions): Promise<IPickFilesResult>;

    //
    // Presents the native share/save sheet for one finished sandbox-relative file, deletes the temp
    // copy on every exit, and resolves with the path (or null when cancelled).
    //
    exportFile(options: IExportFileOptions): Promise<IExportFileResult>;

    //
    // Presents a single native share/save sheet for several finished sandbox-relative files, deletes
    // each temp copy on every exit, and resolves with the paths (or null when cancelled).
    //
    exportFiles(options: IExportFilesOptions): Promise<IExportFilesResult>;

    //
    // Asks for the photo library permission and reports whether it was granted.
    //
    requestMediaPermission(): Promise<IMediaPermissionResult>;

    //
    // Test-only: stages the answer to the next photo library delete request, instead of presenting
    // the system confirmation an automated test cannot tap. Nothing stages one in production.
    //
    stageMediaDeleteOutcome(options: IStageMediaDeleteOptions): Promise<void>;

    //
    // Starts the background automatic import: the loop that asks the plan-auto-import task what to
    // do, imports what it says, waits and asks again.
    //
    // On Android this is a foreground service, which keeps working with the app off screen and the
    // screen off, and posts the ongoing notification the platform requires of one. On iOS it is a
    // loop inside the plugin, which runs while the app is foregrounded, plus a background processing
    // task the system schedules when it chooses. Calling it while it is already started does
    // nothing.
    //
    startBackgroundImport(): Promise<void>;

    //
    // Stops the background automatic import and cancels the import in flight, leaving nothing
    // behind: no service, no notification, no scheduled background task.
    //
    // Safe to call when nothing is running, which is what a freshly launched app does when it finds
    // automatic import switched off: the service it is stopping may have been started by a previous
    // life of the WebView.
    //
    stopBackgroundImport(): Promise<void>;

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
