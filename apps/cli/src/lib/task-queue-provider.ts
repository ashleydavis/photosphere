import { TaskQueue } from "task-queue";
import type { ITaskQueue } from "task-queue";
import type { ITaskQueueProvider } from "api";
import os from "node:os";

//
// Task queue provider that lazily creates task queues when needed.
//
export class TaskQueueProvider implements ITaskQueueProvider {
    private taskQueueInstance: ITaskQueue | null = null;
    private maxWorkers: number;

    constructor(maxWorkers?: number) {
        // Default to number of CPUs if not specified
        this.maxWorkers = maxWorkers ?? os.cpus().length;
    }

    async create(): Promise<ITaskQueue> {
        if (!this.taskQueueInstance) {
            // Worker path resolved relative to project root (per Bun docs)
            this.taskQueueInstance = new TaskQueue(this.maxWorkers, "./worker.ts");
        }
        return this.taskQueueInstance;
    }
}

