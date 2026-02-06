import { TaskQueue } from "task-queue";
import type { ITaskQueue } from "task-queue";
import type { ITaskQueueProvider } from "task-queue";
import { WorkerBackendBun, type IWorkerInfo, type IWorkerBackendOptions } from "./worker-backend-bun";
import { registerStateProvider, updateStateProvider } from "debug-server";
import type { IUuidGenerator, ITimestampProvider } from "utils";

//
// Task queue provider that lazily creates task queues when needed.
//
export class TaskQueueProviderBun implements ITaskQueueProvider {
    private maxWorkers: number;
    private taskTimeout: number;
    private workerOptions: IWorkerBackendOptions;
    private debug: boolean;
    private uuidGenerator: IUuidGenerator;
    private timestampProvider: ITimestampProvider;

    constructor(maxWorkers: number, taskTimeout: number, workerOptions: IWorkerBackendOptions, debug: boolean, uuidGenerator: IUuidGenerator, timestampProvider: ITimestampProvider) {
        this.maxWorkers = maxWorkers;
        this.taskTimeout = taskTimeout;
        this.workerOptions = workerOptions;
        this.debug = debug;
        this.uuidGenerator = uuidGenerator;
        this.timestampProvider = timestampProvider;
    }

    async create(): Promise<ITaskQueue> {
        const workerBackend = new WorkerBackendBun(this.maxWorkers, this.taskTimeout, this.workerOptions);
        const taskQueue = new TaskQueue(this.uuidGenerator, this.timestampProvider, this.taskTimeout, workerBackend);
        
        // If debug mode is enabled, register state provider for polling
        if (this.debug) {
            // Register state provider that will be polled every minute
            // Capture taskQueue and workerBackend in closure for state provider access
            registerStateProvider("taskQueue", () => {
                const workers = workerBackend.getWorkerState() || [];
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
            workerBackend.onWorkerStateChange(() => {
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

