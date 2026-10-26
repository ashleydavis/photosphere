import type { IAddTask, ICoreErrorEvent, IJsonObject, IJsonValue, IMessageCallback, IPlatformInfo, ITaskCompletedEvent, ITaskEvent, ITestCommandEvent, IToolOutput, IZiggyBridge, LogLevel } from "ziggy";

//
// A message the page sent with send or invoke, or one of Ziggy's own calls that sends a message.
//
export interface IRecordedMessage {
    // The name of a message of Photosphere's own (the name it was sent with), or the name of Ziggy's own message.
    name: string;

    // The data it carried.
    data: IJsonValue;
}

//
// A fake of the bridge a native app injects, which records what the page sends and lets a test play the core's events. An
// invoke is answered with the reply a test set for the message's name, and an invoke of a name with no reply set rejects, as the
// core does for a name it does not know.
//
export class FakeZiggy implements IZiggyBridge {
    // Every send and every one-way Ziggy call, in order.
    sent: IRecordedMessage[] = [];

    // Every invoke and every Ziggy call that waits for a response, in order.
    invoked: IRecordedMessage[] = [];

    // The reply to give for each name an invoke is made with.
    replies: Map<string, IJsonValue> = new Map();

    // The names of Ziggy's own events whose listener was removed, in order.
    removed: string[] = [];

    // The callbacks registered for each of Ziggy's own events, and for the app's own events under "event".
    private listeners: Map<string, IMessageCallback<any>[]> = new Map();

    invoke<TResponse>(name: string, data: IJsonValue): Promise<TResponse> {
        this.invoked.push({
            name,
            data,
        });
        return this.respond<TResponse>(name);
    }

    send(name: string, data: IJsonValue): void {
        this.sent.push({
            name,
            data,
        });
    }

    onEvent<TData>(callback: IMessageCallback<TData>): void {
        this.addListener("event", callback);
    }

    removeEventListener<TData>(callback: IMessageCallback<TData>): void {
        this.removeListener("event", callback);
    }

    getPlatform(): Promise<IPlatformInfo> {
        this.invoked.push({
            name: "get-platform",
            data: null,
        });
        return this.respond<IPlatformInfo>("get-platform");
    }

    addTask(task: IAddTask): void {
        this.sent.push({
            name: "add-task",
            data: task as any,
        });
    }

    cancelTasks(source: string): void {
        this.sent.push({
            name: "cancel-tasks",
            data: source,
        });
    }

    onTaskEvent<TData>(callback: IMessageCallback<ITaskEvent<TData>>): void {
        this.addListener("task-event", callback);
    }

    removeTaskEventListener<TData>(callback: IMessageCallback<ITaskEvent<TData>>): void {
        this.removeListener("task-event", callback);
    }

    onTaskCompleted(callback: IMessageCallback<ITaskCompletedEvent>): void {
        this.addListener("task-completed", callback);
    }

    removeTaskCompletedListener(callback: IMessageCallback<ITaskCompletedEvent>): void {
        this.removeListener("task-completed", callback);
    }

    onCoreError(callback: IMessageCallback<ICoreErrorEvent>): void {
        this.addListener("core-error", callback);
    }

    removeCoreErrorListener(callback: IMessageCallback<ICoreErrorEvent>): void {
        this.removeListener("core-error", callback);
    }

    onTestCommand<TCommand>(callback: IMessageCallback<ITestCommandEvent<TCommand>>): void {
        this.addListener("test-command", callback);
    }

    removeTestCommandListener<TCommand>(callback: IMessageCallback<ITestCommandEvent<TCommand>>): void {
        this.removeListener("test-command", callback);
    }

    async sendTestResult(requestId: number, result: IJsonValue): Promise<void> {
        this.invoked.push({
            name: "test-result",
            data: {
                requestId,
                result,
            },
        });
        await this.respond<IJsonValue>("test-result");
    }

    testUiReady(): void {
        this.sent.push({
            name: "test-ui-ready",
            data: null,
        });
    }

    // Records the line as the "log" message, with the error text and the tool output only when they were given.
    log(level: LogLevel, message: string, errorText?: string, toolOutput?: IToolOutput): void {
        const data: IJsonObject = {
            level,
            message,
        };
        if (errorText !== undefined) {
            data.error = errorText;
        }
        if (toolOutput !== undefined) {
            data.toolData = toolOutput as IJsonObject;
        }
        this.sent.push({
            name: "log",
            data,
        });
    }

    getPathForFile(_file: File): string | undefined {
        return undefined;
    }

    // Plays one of Ziggy's own events from the core to the callbacks registered for it, or with the name "event", an event of the app's own.
    emit(name: string, data: IJsonValue): void {
        for (const callback of this.listeners.get(name) ?? []) {
            callback(data);
        }
    }

    // How many callbacks are registered for one of Ziggy's own events, or with the name "event", for the app's own events.
    listenerCount(name: string): number {
        return (this.listeners.get(name) ?? []).length;
    }

    // Answers with the reply a test set for the name, or rejects when there is none.
    private respond<TResponse>(name: string): Promise<TResponse> {
        if (!this.replies.has(name)) {
            return Promise.reject(new Error(`No reply set for ${name}`));
        }
        return Promise.resolve(this.replies.get(name) as TResponse);
    }

    // Registers a callback under a name.
    private addListener(name: string, callback: IMessageCallback<any>): void {
        const existing = this.listeners.get(name) ?? [];
        existing.push(callback);
        this.listeners.set(name, existing);
    }

    // Removes a callback registered under a name, and records the name.
    private removeListener(name: string, callback: IMessageCallback<any>): void {
        this.removed.push(name);
        this.listeners.set(name, (this.listeners.get(name) ?? []).filter(listener => listener !== callback));
    }
}
