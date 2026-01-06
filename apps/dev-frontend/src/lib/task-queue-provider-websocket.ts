import type { ITaskQueue } from "task-queue";
import type { ITaskQueueProvider } from "task-queue";
import { TaskQueueWebSocket } from "./task-queue-websocket";

//
// WebSocket-based task queue provider
// Creates task queues that communicate with dev-server via WebSocket
//
export class TaskQueueProviderWebSocket implements ITaskQueueProvider {
    private ws: WebSocket;

    constructor(ws: WebSocket) {
        this.ws = ws;
    }

    async create(): Promise<ITaskQueue> {
        return new TaskQueueWebSocket(this.ws);
    }
}

