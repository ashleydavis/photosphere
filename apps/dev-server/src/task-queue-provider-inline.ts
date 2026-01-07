import type { ITaskQueue } from "task-queue";
import type { ITaskQueueProvider } from "task-queue";
import { TaskQueueInline } from "./task-queue-inline";
import { RandomUuidGenerator, TimestampProvider } from "utils";

//
// Inline task queue provider
// Creates task queues that execute tasks directly without workers
//
export class TaskQueueProviderInline implements ITaskQueueProvider {
    private uuidGenerator: RandomUuidGenerator;
    private timestampProvider: TimestampProvider;
    private maxConcurrent = 10;

    constructor(uuidGenerator: RandomUuidGenerator) {
        this.uuidGenerator = uuidGenerator;
        this.timestampProvider = new TimestampProvider();
    }

    async create(): Promise<ITaskQueue> {
        // Create a new queue for each WebSocket connection
        return new TaskQueueInline(
            this.maxConcurrent,
            this.uuidGenerator,
            this.timestampProvider,
            {
                verbose: true,
                sessionId: this.uuidGenerator.generate(),
            }
        );
    }
}

