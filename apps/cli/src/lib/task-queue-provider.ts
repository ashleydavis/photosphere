import { TaskQueue, type IWorkerOptions, type IWorkerInfo, TaskStatus } from "task-queue";
import type { ITaskQueue } from "task-queue";
import type { ITaskQueueProvider } from "api";
import os from "node:os";
import { registerStateProvider, updateStateProvider } from "debug-server";

//
// Task queue provider that lazily creates task queues when needed.
//
export class TaskQueueProvider implements ITaskQueueProvider {
    private taskQueueInstance: ITaskQueue | null = null;
    private maxWorkers: number;
    private taskTimeout: number;
    private workerOptions?: IWorkerOptions;
    private debug: boolean;

    constructor(maxWorkers?: number, taskTimeout?: number, workerOptions?: IWorkerOptions, debug: boolean = false) {
        // Default to number of CPUs if not specified
        this.maxWorkers = maxWorkers ?? os.cpus().length;
        // Default to 10 minutes (600000ms) if not specified
        this.taskTimeout = taskTimeout ?? 600000;
        this.workerOptions = workerOptions;
        this.debug = debug;
    }

    async create(): Promise<ITaskQueue> {
        if (!this.taskQueueInstance) {
            // Worker path resolved relative to project root (per Bun docs)
            this.taskQueueInstance = new TaskQueue(this.maxWorkers, "./worker.ts", undefined, undefined, this.taskTimeout, this.workerOptions);
            
            // If debug mode is enabled, register state provider for polling
            if (this.debug) {
                // Register state provider that will be polled every minute
                registerStateProvider("taskQueue", () => {
                    const workers = this.taskQueueInstance!.getWorkerState();
                    const queueStatus = this.taskQueueInstance!.getStatus();
                    const succeededCount = this.taskQueueInstance!.getSuccessfulTaskResults().length;
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
                        completedTasks: this.taskQueueInstance!.getAllTaskResults().filter(t => t.status === TaskStatus.Completed || t.status === TaskStatus.Failed),
                        succeededTasks: this.taskQueueInstance!.getSuccessfulTaskResults(),
                        failedTasks: this.taskQueueInstance!.getFailedTaskResults(),
                        workerStats: this.calculateWorkerStats(workers),
                        tasksProcessedChart
                    };
                });
                
                // Also trigger updates on state changes (for immediate updates)
                this.taskQueueInstance.onWorkerStateChange(() => {
                    updateStateProvider("taskQueue");
                });
            }
        }
        return this.taskQueueInstance;
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

