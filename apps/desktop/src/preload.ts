import { contextBridge, ipcRenderer, webUtils } from 'electron';
import type { IElectronAPI, IImportSession, IRendererLogMessage, ISaveAssetItem, IToolsStatus, IDatabaseEntry, IVaultSecret } from 'electron-defs';

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
    importAssets: (paths?: string[]): Promise<IImportSession | undefined> => {
        return ipcRenderer.invoke('import-assets', paths);
    },
    checkTools: (): Promise<IToolsStatus> => {
        return ipcRenderer.invoke('check-tools');
    },
    checkDatabaseExists: (databasePath: string): Promise<boolean> => {
        return ipcRenderer.invoke('check-database-exists', databasePath);
    },
    getPathForFile: (file: File): string => {
        return webUtils.getPathForFile(file);
    },
    getDatabases: (): Promise<IDatabaseEntry[]> => {
        return ipcRenderer.invoke('get-databases');
    },
    addDatabase: (entry: Omit<IDatabaseEntry, 'id'>): Promise<IDatabaseEntry> => {
        return ipcRenderer.invoke('add-database', entry);
    },
    updateDatabase: (entry: IDatabaseEntry): Promise<void> => {
        return ipcRenderer.invoke('update-database', entry);
    },
    removeDatabaseEntry: (id: string): Promise<void> => {
        return ipcRenderer.invoke('remove-database-entry', id);
    },
    pickFolder: (): Promise<string | undefined> => {
        return ipcRenderer.invoke('pick-folder');
    },
    vaultGet: (name: string): Promise<IVaultSecret | undefined> => {
        return ipcRenderer.invoke('vault-get', name);
    },
    vaultSet: (secret: IVaultSecret): Promise<void> => {
        return ipcRenderer.invoke('vault-set', secret);
    },
    vaultDelete: (name: string): Promise<void> => {
        return ipcRenderer.invoke('vault-delete', name);
    },
    vaultList: (): Promise<IVaultSecret[]> => {
        return ipcRenderer.invoke('vault-list');
    },
    createDatabaseAtPath: (path: string): Promise<void> => {
        return ipcRenderer.invoke('create-database-at-path', path);
    },
    listS3Dirs: (credentialId: string, bucket: string, prefix: string): Promise<string[]> => {
        return ipcRenderer.invoke('list-s3-dirs', credentialId, bucket, prefix);
    },
    getRecentDatabases: (): Promise<IDatabaseEntry[]> => {
        return ipcRenderer.invoke('get-recent-databases');
    },
};

contextBridge.exposeInMainWorld('electronAPI', electronAPI);

