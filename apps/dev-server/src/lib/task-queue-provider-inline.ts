import type { ITaskQueue } from "task-queue";
import type { ITaskQueueProvider } from "task-queue";
import { TaskQueue } from "task-queue";
import { WorkerBackendInline } from "./worker-backend-inline";
import type { IUuidGenerator, ITimestampProvider } from "utils";

//
// Inline task queue provider
// Creates task queues that execute tasks directly without workers
//
export class TaskQueueProviderInline implements ITaskQueueProvider {
    private uuidGenerator: IUuidGenerator;
    private timestampProvider: ITimestampProvider;
    private sessionId: string;
    private maxConcurrent = 10;

    constructor(uuidGenerator: IUuidGenerator, timestampProvider: ITimestampProvider, sessionId: string) {
        this.uuidGenerator = uuidGenerator;
        this.timestampProvider = timestampProvider;
        this.sessionId = sessionId;
    }

    async create(): Promise<ITaskQueue> {
        // Create a new queue for each WebSocket connection
        const workerBackend = new WorkerBackendInline(
            this.maxConcurrent,
            this.uuidGenerator,
            this.timestampProvider,
            {
                verbose: true,
                sessionId: this.sessionId,
            }
        );
        return new TaskQueue(this.uuidGenerator, this.timestampProvider, 0, workerBackend);
    }
}

