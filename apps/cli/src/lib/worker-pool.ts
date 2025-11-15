import type { Worker as BunWorkerType } from "bun";
import os from "os";
import path from "path";
import { fileURLToPath } from "url";
import { IWorkerPool, IWorkerTask, IWorkerResult } from "api";

// Use Bun's Worker constructor
const BunWorker = globalThis.Worker as typeof globalThis.Worker;

//
// Pending task with callback
//
interface PendingTask {
    taskId: string;
    resolve: (result: any) => void;
    reject: (error: Error) => void;
}

//
// Worker pool for managing Bun workers
//
export class WorkerPool implements IWorkerPool {
    private workers: BunWorkerType[] = [];
    private availableWorkers: BunWorkerType[] = [];
    private taskQueue: Array<{
        task: IWorkerTask;
        resolve: (result: any) => void;
        reject: (error: Error) => void;
    }> = [];
    private pendingTasks = new Map<string, PendingTask>();
    private workerCount: number;
    private workerPath: string;

    constructor(workerCount?: number, workerPath?: string) {
        this.workerCount = workerCount ?? this.getDefaultWorkerCount();
        
        // Get the worker path - handle both ESM and CommonJS
        if (workerPath) {
            this.workerPath = workerPath;
        } else {
            // Use import.meta.url to get current file location
            const currentFile = typeof __filename !== 'undefined' 
                ? __filename 
                : fileURLToPath(import.meta.url);
            const currentDir = path.dirname(currentFile);
            this.workerPath = path.join(currentDir, 'workers', 'file-worker.ts');
        }
    }

    //
    // Gets the default worker count based on CPU count
    //
    private getDefaultWorkerCount(): number {
        const cpus = os.cpus().length;
        return Math.max(1, Math.floor(cpus / 4));
    }

    //
    // Gets or creates a worker
    //
    private getWorker(): BunWorkerType | null {
        if (this.availableWorkers.length > 0) {
            return this.availableWorkers.pop()!;
        }

        if (this.workers.length < this.workerCount) {
            const worker = new BunWorker(this.workerPath) as BunWorkerType;
            
            worker.onmessage = (event: any) => {
                const { taskId, result, error } = event.data as any;
                const pendingTask = this.pendingTasks.get(taskId);
                
                if (pendingTask) {
                    this.pendingTasks.delete(taskId);
                    this.availableWorkers.push(worker);
                    
                    if (error) {
                        pendingTask.reject(new Error(error));
                    } else {
                        // Convert base64 hash back to Buffer if needed
                        if (result && result.hash && typeof result.hash === 'string') {
                            result.hash = Buffer.from(result.hash, 'base64');
                        }
                        pendingTask.resolve(result);
                    }
                    
                    // Process next task in queue
                    this.processQueue();
                }
            };

            worker.onerror = (error: any) => {
                console.error('Worker error:', error);
                // Remove failed worker and process queue
                this.workers = this.workers.filter(w => w !== worker);
                this.availableWorkers = this.availableWorkers.filter(w => w !== worker);
                this.processQueue();
            };

            this.workers.push(worker);
            return worker;
        }

        // All workers busy, return null to queue task
        return null;
    }

    //
    // Processes the next task in the queue
    //
    private processQueue(): void {
        if (this.taskQueue.length === 0) {
            return;
        }

        const worker = this.getWorker();
        if (!worker) {
            return; // All workers busy, wait for one to become available
        }

        const task = this.taskQueue.shift();
        if (!task) {
            this.availableWorkers.push(worker);
            return;
        }

        const taskId = Math.random().toString(36).substring(7);
        this.pendingTasks.set(taskId, {
            taskId,
            resolve: task.resolve,
            reject: task.reject,
        });

        worker.postMessage({
            taskId,
            ...task.task,
        });
    }

    //
    // Executes a task using a worker
    //
    async execute<T extends IWorkerTask>(task: T): Promise<IWorkerResult<T>> {
        return new Promise((resolve, reject) => {
            this.taskQueue.push({
                task,
                resolve: resolve as any,
                reject,
            });
            this.processQueue();
        });
    }

    //
    // Executes multiple tasks in parallel
    //
    async executeBatch<T extends IWorkerTask>(tasks: T[]): Promise<Array<IWorkerResult<T> | Error>> {
        const results = await Promise.allSettled(
            tasks.map(task => this.execute(task))
        );

        return results.map(result => {
            if (result.status === 'fulfilled') {
                return result.value;
            } else {
                return result.reason instanceof Error ? result.reason : new Error(String(result.reason));
            }
        });
    }

    //
    // Terminates all workers
    //
    async terminate(): Promise<void> {
        await Promise.all(this.workers.map(worker => worker.terminate()));
        this.workers = [];
        this.availableWorkers = [];
        this.taskQueue = [];
        this.pendingTasks.clear();
    }

    //
    // Gets the current worker count
    //
    getWorkerCount(): number {
        return this.workers.length;
    }

    //
    // Gets the configured worker count
    //
    getConfiguredWorkerCount(): number {
        return this.workerCount;
    }
}

