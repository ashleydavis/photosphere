import { TaskQueueBun } from "./task-queue-bun";
import { type IWorkerInfo } from "task-queue";
import type { ITaskQueue } from "task-queue";
import type { IWorkerOptions } from "./worker-init";
import type { ITaskQueueProvider } from "task-queue";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { registerStateProvider, updateStateProvider } from "debug-server";
import type { IUuidGenerator, ITimestampProvider } from "utils";

//
// Task queue provider that lazily creates task queues when needed.
//
export class TaskQueueProviderBun implements ITaskQueueProvider {
    private maxWorkers: number;
    private taskTimeout: number;
    private workerOptions: IWorkerOptions;
    private debug: boolean;
    private uuidGenerator: IUuidGenerator;
    private timestampProvider: ITimestampProvider;

    constructor(maxWorkers: number, taskTimeout: number, workerOptions: IWorkerOptions, debug: boolean, uuidGenerator: IUuidGenerator, timestampProvider: ITimestampProvider) {
        this.maxWorkers = maxWorkers;
        this.taskTimeout = taskTimeout;
        this.workerOptions = workerOptions;
        this.debug = debug;
        this.uuidGenerator = uuidGenerator;
        this.timestampProvider = timestampProvider;
    }

    async create(): Promise<ITaskQueue> {
        const baseWorkingDirectory = join(tmpdir(), "task-queue");
        const taskQueue = new TaskQueueBun(this.maxWorkers, baseWorkingDirectory, this.uuidGenerator, this.timestampProvider, this.taskTimeout, this.workerOptions);
        
        // If debug mode is enabled, register state provider for polling
        if (this.debug) {
            // Register state provider that will be polled every minute
            // Capture taskQueue in closure for state provider access
            registerStateProvider("taskQueue", () => {
                const workers = taskQueue.getWorkerState();
                const queueStatus = taskQueue.getStatus();
                const succeededCount = queueStatus.completed;
                const failedCount = queueStatus.failed;
                const totalCompleted = succeededCount + failedCount;
                
                const taskStats = {
                    ...queueStatus,
                    succeeded: succeededCount,
                    percentSucceeded: totalCompleted > 0 ? Math.round((succeededCount / totalCompleted) * 100 * 100) / 100 : 0,
                    percentFailed: totalCompleted > 0 ? Math.round((failedCount / totalCompleted) * 100 * 100) / 100 : 0
                };
                
                // Create bar chart data for tasks processed per worker
                const tasksProcessedChart = {
                    __barChart: true,
                    title: "Tasks Processed per Worker",
                    items: workers.map(worker => ({
                        label: `Worker ${worker.workerId}`,
                        value: worker.tasksProcessed,
                        displayValue: worker.tasksProcessed
                    }))
                };
                
                return {
                    workers,
                    taskStats,
                    workerStats: this.calculateWorkerStats(workers),
                    tasksProcessedChart
                };
            });
            
            // Also trigger updates on state changes (for immediate updates)
            taskQueue.onWorkerStateChange(() => {
                updateStateProvider("taskQueue");
            });
        }
        
        return taskQueue;
    }

    //
    // Calculates worker statistics for debugging.
    //
    private calculateWorkerStats(workers: IWorkerInfo[]): {
        maxWorkers: number;
        currentWorkers: number;
        allocatedWorkers: number;
        totalTasksProcessed: number;
        averageTasksPerWorker: number;
        percentCurrentToMax: number;
        percentAllocatedToCurrent: number;
        percentAllocatedToMax: number;
    } {
        const maxWorkers = this.maxWorkers;
        const currentWorkers = workers.length;
        const allocatedWorkers = workers.filter(w => w.isReady).length;
        const totalTasksProcessed = workers.reduce((sum, w) => sum + w.tasksProcessed, 0);
        const averageTasksPerWorker = currentWorkers > 0 ? totalTasksProcessed / currentWorkers : 0;
        
        const percentCurrentToMax = maxWorkers > 0 ? (currentWorkers / maxWorkers) * 100 : 0;
        const percentAllocatedToCurrent = currentWorkers > 0 ? (allocatedWorkers / currentWorkers) * 100 : 0;
        const percentAllocatedToMax = maxWorkers > 0 ? (allocatedWorkers / maxWorkers) * 100 : 0;
        
        return {
            maxWorkers,
            currentWorkers,
            allocatedWorkers,
            totalTasksProcessed,
            averageTasksPerWorker: Math.round(averageTasksPerWorker * 100) / 100,
            percentCurrentToMax: Math.round(percentCurrentToMax * 100) / 100,
            percentAllocatedToCurrent: Math.round(percentAllocatedToCurrent * 100) / 100,
            percentAllocatedToMax: Math.round(percentAllocatedToMax * 100) / 100
        };
    }
}

