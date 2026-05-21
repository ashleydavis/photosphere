import { contextBridge, ipcRenderer, webUtils } from 'electron';
import type { IElectronAPI, IImportSession, IRendererLogMessage, ISaveAssetItem, IToolsStatus, IDatabaseEntry } from 'electron-defs';
import type { ISecret } from 'vault';

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
    importDirectories: (paths?: string[]): Promise<IImportSession | undefined> => {
        return ipcRenderer.invoke('import-directories', paths);
    },
    importFiles: (paths?: string[]): Promise<IImportSession | undefined> => {
        return ipcRenderer.invoke('import-files', paths);
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
    addDatabase: (entry: IDatabaseEntry): Promise<IDatabaseEntry> => {
        return ipcRenderer.invoke('add-database', entry);
    },
    updateDatabase: (originalName: string, entry: IDatabaseEntry): Promise<void> => {
        return ipcRenderer.invoke('update-database', originalName, entry);
    },
    removeDatabaseEntry: (name: string): Promise<void> => {
        return ipcRenderer.invoke('remove-database-entry', name);
    },
    findDatabase: (name: string): Promise<IDatabaseEntry | undefined> => {
        return ipcRenderer.invoke('find-database', name);
    },
    pickFolder: (): Promise<string | undefined> => {
        return ipcRenderer.invoke('pick-folder');
    },
    vaultGet: (name: string): Promise<ISecret | undefined> => {
        return ipcRenderer.invoke('vault-get', name);
    },
    vaultSet: (secret: ISecret): Promise<void> => {
        return ipcRenderer.invoke('vault-set', secret);
    },
    vaultDelete: (name: string): Promise<void> => {
        return ipcRenderer.invoke('vault-delete', name);
    },
    vaultList: (): Promise<ISecret[]> => {
        return ipcRenderer.invoke('vault-list');
    },
    createDatabaseAtPath: (path: string): Promise<void> => {
        return ipcRenderer.invoke('create-database-at-path', path);
    },
    listS3Dirs: (s3Key: string, bucket: string, prefix: string): Promise<string[]> => {
        return ipcRenderer.invoke('list-s3-dirs', s3Key, bucket, prefix);
    },
    getRecentDatabases: (): Promise<IDatabaseEntry[]> => {
        return ipcRenderer.invoke('get-recent-databases');
    },
    removeRecentDatabaseName: (name: string): Promise<void> => {
        return ipcRenderer.invoke('remove-recent-database-name', name);
    },
    startShareReceive: (code: string): Promise<void> => {
        return ipcRenderer.invoke('start-share-receive', code);
    },
    waitShareReceive: (): Promise<unknown> => {
        return ipcRenderer.invoke('wait-share-receive');
    },
    cancelShareReceive: (): Promise<void> => {
        return ipcRenderer.invoke('cancel-share-receive');
    },
    waitForReceiver: (payload: unknown, code: string): Promise<unknown> => {
        return ipcRenderer.invoke('wait-for-receiver', payload, code);
    },
    sendToReceiver: (endpoint: unknown): Promise<boolean> => {
        return ipcRenderer.invoke('send-to-receiver', endpoint);
    },
    cancelShareSend: (): Promise<void> => {
        return ipcRenderer.invoke('cancel-share-send');
    },
    importSharePayload: (payload: unknown, conflictResolutions: unknown): Promise<void> => {
        return ipcRenderer.invoke('import-share-payload', payload, conflictResolutions);
    },
    markUpdateShown: (version: string): Promise<void> => {
        return ipcRenderer.invoke('mark-update-shown', version);
    },
    markNewsShown: (newsId: string): Promise<void> => {
        return ipcRenderer.invoke('mark-news-shown', newsId);
    },
};

contextBridge.exposeInMainWorld('electronAPI', electronAPI);

