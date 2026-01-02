import type { ITaskQueue } from "task-queue";
import type { ITaskQueueProvider } from "task-queue";
import { WebSocketTaskQueue } from "./websocket-task-queue";

//
// WebSocket-based task queue provider
// Creates task queues that communicate with dev-server via WebSocket
//
export class WebSocketTaskQueueProvider implements ITaskQueueProvider {
    private ws: WebSocket;

    constructor(ws: WebSocket) {
        this.ws = ws;
    }

    async create(): Promise<ITaskQueue> {
        return new WebSocketTaskQueue(this.ws);
    }
}

