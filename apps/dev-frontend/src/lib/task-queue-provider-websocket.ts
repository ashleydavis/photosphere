import type { ITaskQueue } from "task-queue";
import type { ITaskQueueProvider } from "task-queue";
import { TaskQueue } from "task-queue";
import { WorkerBackendWebSocket } from "./worker-backend-websocket";
import type { IUuidGenerator, ITimestampProvider } from "utils";

//
// WebSocket-based task queue provider
// Creates task queues that communicate with dev-server via WebSocket
//
export class TaskQueueProviderWebSocket implements ITaskQueueProvider {
    private ws: WebSocket;
    private uuidGenerator: IUuidGenerator;
    private timestampProvider: ITimestampProvider;
    private queue: ITaskQueue | undefined;

    constructor(ws: WebSocket, uuidGenerator: IUuidGenerator, timestampProvider: ITimestampProvider) {
        this.ws = ws;
        this.uuidGenerator = uuidGenerator;
        this.timestampProvider = timestampProvider;
    }

    get(): ITaskQueue {
        if (this.queue) {
            return this.queue;
        }

        const workerBackend = new WorkerBackendWebSocket(this.ws);
        this.queue = new TaskQueue(this.uuidGenerator, this.timestampProvider, 0, workerBackend);
        return this.queue;
    }
}

