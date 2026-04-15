//
// TaskContext — implements ITaskContext for a single worker task.
//
import type { ITaskContext } from "./types";
import type { IUuidGenerator, ITimestampProvider } from "utils";

//
// Implements ITaskContext for a single worker task.
//
export class TaskContext implements ITaskContext {
    //
    // Generates unique identifiers.
    //
    readonly uuidGenerator: IUuidGenerator;

    //
    // Provides the current timestamp.
    //
    readonly timestampProvider: ITimestampProvider;

    //
    // Unique identifier for the session this task belongs to.
    //
    readonly sessionId: string;

    //
    // The unique ID of the currently executing task.
    //
    readonly taskId: string;

    //
    // Whether this task has been cancelled.
    //
    private _isCancelled: boolean = false;

    //
    // Sends a message back to the caller.
    //
    private readonly sendMessageFn: (message: any) => void;

    constructor(
        uuidGenerator: IUuidGenerator,
        timestampProvider: ITimestampProvider,
        sessionId: string,
        taskId: string,
        sendMessageFn: (message: any) => void
    ) {
        this.uuidGenerator = uuidGenerator;
        this.timestampProvider = timestampProvider;
        this.sessionId = sessionId;
        this.taskId = taskId;
        this.sendMessageFn = sendMessageFn;
    }

    //
    // Sends a message back to the caller via the main process.
    //
    sendMessage(msg: any): void {
        this.sendMessageFn(msg);
    }

    //
    // Marks this task as cancelled.
    //
    cancel(): void {
        this._isCancelled = true;
    }

    //
    // Returns true if this task has been cancelled.
    //
    isCancelled(): boolean {
        return this._isCancelled;
    }

}
