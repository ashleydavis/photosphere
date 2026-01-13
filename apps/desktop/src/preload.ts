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
};

contextBridge.exposeInMainWorld('electronAPI', electronAPI);

