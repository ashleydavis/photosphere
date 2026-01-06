import type { ITaskQueue } from "task-queue";
import type { ITaskQueueProvider } from "task-queue";
import { TaskQueueInline } from "./task-queue-inline";
import { RandomUuidGenerator, TimestampProvider } from "utils";
import { join } from "node:path";
import { tmpdir } from "node:os";

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
        const baseWorkingDirectory = join(tmpdir(), "task-queue");
        return new TaskQueueInline(
            this.maxConcurrent,
            baseWorkingDirectory,
            this.uuidGenerator,
            this.timestampProvider,
            {
                verbose: true,
                sessionId: this.uuidGenerator.generate(),
            }
        );
    }
}

