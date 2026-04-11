//
// Log levels supported by the logging system
//
export type LogLevel = 'info' | 'verbose' | 'error' | 'exception' | 'warn' | 'debug' | 'tool';

//
// Log message structure sent from renderer to main process
//
export interface IRendererLogMessage {
    level: LogLevel;
    message: string;
    error?: string; // For exception level - stack trace
    toolData?: { stdout?: string; stderr?: string }; // For tool level
}

//
// Identifies a single asset to be saved to disk.
//
export interface ISaveAssetItem {
    //
    // The ID of the asset.
    //
    assetId: string;

    //
    // The asset type to fetch (e.g. "asset").
    //
    assetType: string;

    //
    // The original filename to save as.
    //
    filename: string;
}

//
// Type definition for Electron API exposed via preload script
// Shared between desktop main process and desktop frontend
//
export interface IElectronAPI {
    addTask: (taskType: string, data: any, source: string, taskId?: string) => void;
    cancelTasks: (source: string) => void;
    onMessage: (messageType: string, callback: (data: any) => void) => void;
    removeAllListeners: (messageType: string) => void;
    openDatabase: () => Promise<void>;
    createDatabase: () => Promise<void>;
    removeDatabase: (databasePath: string) => Promise<void>;
    notifyDatabaseOpened: (databasePath: string) => Promise<void>;
    notifyDatabaseClosed: () => Promise<void>;
    getConfig: (key: string) => Promise<any | undefined>;
    setConfig: (key: string, value: unknown) => Promise<void>;

    //
    // Notifies the main process that the database was edited.
    // The main process debounces this signal and triggers a background sync.
    //
    notifyDatabaseEdited: () => void;

    // Logging methods - forward logs from renderer to main process for file logging
    log: (message: IRendererLogMessage) => void;

    //
    // Sends an FPS measurement to the main process for writing to a log file.
    //
    sendFps: (fps: number) => void;

    //
    // Opens a save dialog and, if confirmed, enqueues a background task to stream the asset to the chosen file.
    //
    saveAsset: (assetId: string, assetType: string, filename: string, databasePath: string) => Promise<void>;

    //
    // Opens a folder picker and, if confirmed, enqueues background tasks to save all assets into it.
    //
    saveAssets: (assets: ISaveAssetItem[], databasePath: string) => Promise<void>;

    //
    // Opens the given path in the system's file manager.
    //
    openPath: (path: string) => Promise<void>;
}

