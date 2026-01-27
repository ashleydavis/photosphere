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
    notifyDatabaseOpened: (databasePath: string): Promise<void> => {
        return ipcRenderer.invoke('notify-database-opened', databasePath);
    },
    notifyDatabaseClosed: (): Promise<void> => {
        return ipcRenderer.invoke('notify-database-closed');
    },
    getTheme: (): Promise<'light' | 'dark' | 'system'> => {
        return ipcRenderer.invoke('get-theme');
    },
    setTheme: (theme: 'light' | 'dark' | 'system'): Promise<void> => {
        return ipcRenderer.invoke('set-theme', theme);
    },
};

contextBridge.exposeInMainWorld('electronAPI', electronAPI);

