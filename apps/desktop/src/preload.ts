import { contextBridge, ipcRenderer } from 'electron';
import type { IElectronAPI, IRendererLogMessage, ISaveAssetItem } from 'electron-defs';

// Expose generic task queue API
const electronAPI: IElectronAPI = {
    addTask: (taskType: string, data: any, source: string, taskId?: string): void => {
        ipcRenderer.send('add-task', taskType, data, source, taskId);
    },
    cancelTasks: (source: string): void => {
        ipcRenderer.send('cancel-tasks', source);
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
    createDatabase: (): Promise<void> => {
        return ipcRenderer.invoke('create-database');
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
    getConfig: (key: string): Promise<unknown> => {
        return ipcRenderer.invoke('get-config', key);
    },
    setConfig: (key: string, value: unknown): Promise<void> => {
        return ipcRenderer.invoke('set-config', key, value);
    },
    notifyDatabaseEdited: (): void => {
        ipcRenderer.send('notify-database-edited');
    },
    log: (message: IRendererLogMessage): void => {
        ipcRenderer.send('renderer-log', message);
    },
    sendFps: (fps: number): void => {
        ipcRenderer.send('fps-measurement', fps);
    },
    saveAsset: (assetId: string, assetType: string, filename: string, databasePath: string): Promise<void> => {
        return ipcRenderer.invoke('save-asset', assetId, assetType, filename, databasePath);
    },
    saveAssets: (assets: ISaveAssetItem[], databasePath: string): Promise<void> => {
        return ipcRenderer.invoke('save-assets', assets, databasePath);
    },
    openPath: (path: string): Promise<void> => {
        return ipcRenderer.invoke('open-path', path);
    },
};

contextBridge.exposeInMainWorld('electronAPI', electronAPI);

