import { contextBridge, ipcRenderer } from 'electron';
import type { IElectronAPI } from 'electron-defs';

// Expose generic task queue API
const electronAPI: IElectronAPI = {
    addTask: (taskType: string, data: any, taskId?: string): void => {
        ipcRenderer.send('add-task', taskType, data, taskId);
    },
    onMessage: (messageType: string, callback: (data: any) => void) => {
        ipcRenderer.on(messageType, (_event, data) => {
            callback(data);
        });
    },
    removeAllListeners: (messageType: string) => {
        ipcRenderer.removeAllListeners(messageType);
    },
    openDatabase: (): Promise<void> => {
        return ipcRenderer.invoke('open-file');
    },
    getRecentDatabases: (): Promise<string[]> => {
        return ipcRenderer.invoke('get-recent-databases');
    },
    removeDatabase: (databasePath: string): Promise<void> => {
        return ipcRenderer.invoke('remove-database', databasePath);
    },
    addRecentDatabase: (databasePath: string): Promise<void> => {
        return ipcRenderer.invoke('add-recent-database', databasePath);
    },
};

contextBridge.exposeInMainWorld('electronAPI', electronAPI);

