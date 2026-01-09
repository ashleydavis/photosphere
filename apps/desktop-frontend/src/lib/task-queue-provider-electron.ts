import type { ITaskQueue } from "task-queue";
import type { ITaskQueueProvider } from "task-queue";
import { TaskQueue } from "task-queue";
import { WorkerBackendElectronRenderer } from "./worker-backend-electron-renderer";
import type { IUuidGenerator, ITimestampProvider } from "utils";
import type { IElectronAPI } from "electron-defs";

//
// Electron IPC-based task queue provider
// Creates task queues that communicate with Electron main process via IPC
//
export class TaskQueueProviderElectron implements ITaskQueueProvider {
    private electronAPI: IElectronAPI;
    private uuidGenerator: IUuidGenerator;
    private timestampProvider: ITimestampProvider;

    constructor(electronAPI: IElectronAPI, uuidGenerator: IUuidGenerator, timestampProvider: ITimestampProvider) {
        this.electronAPI = electronAPI;
        this.uuidGenerator = uuidGenerator;
        this.timestampProvider = timestampProvider;
    }

    async create(): Promise<ITaskQueue> {
        const workerBackend = new WorkerBackendElectronRenderer(this.electronAPI);
        return new TaskQueue(this.uuidGenerator, this.timestampProvider, 0, workerBackend);
    }
}

