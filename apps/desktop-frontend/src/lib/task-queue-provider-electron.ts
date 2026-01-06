import type { ITaskQueue } from "task-queue";
import type { ITaskQueueProvider } from "task-queue";
import { TaskQueueElectronRenderer } from "./task-queue-electron-renderer";
import type { IElectronAPI } from "electron-defs";

//
// Electron IPC-based task queue provider
// Creates task queues that communicate with Electron main process via IPC
//
export class TaskQueueProviderElectron implements ITaskQueueProvider {
    private electronAPI: IElectronAPI;

    constructor(electronAPI: IElectronAPI) {
        this.electronAPI = electronAPI;
    }

    async create(): Promise<ITaskQueue> {
        return new TaskQueueElectronRenderer(this.electronAPI);
    }
}

