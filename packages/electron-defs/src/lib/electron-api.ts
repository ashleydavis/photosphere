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
// Identifies an import session so the renderer can track progress and cancel it.
//
export interface IImportSession {
    // Task ID of the add-paths task, for correlating task-completed events.
    importAssetsTaskId: string;

    // Source tag for all tasks in this import; pass to cancelTasks() to cancel.
    sessionId: string;
}

//
// Status of a single required external tool (ImageMagick, ffmpeg, ffprobe).
//
export interface IToolStatus {
    // Whether the tool is available on PATH.
    available: boolean;

    // Version string returned by the tool, if available.
    version?: string;
}

//
// Aggregated availability of all tools required for importing photos and videos.
//
export interface IToolsStatus {
    // Status of the ImageMagick `magick` command.
    magick: IToolStatus;

    // Status of the `ffprobe` command.
    ffprobe: IToolStatus;

    // Status of the `ffmpeg` command.
    ffmpeg: IToolStatus;

    // True when all three tools are available.
    allAvailable: boolean;

    // Names of any missing tools (e.g. ['ImageMagick', 'ffmpeg']).
    missingTools: string[];
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

    //
    // Imports the given paths (files or directories) into the current database.
    // When paths is provided they are used directly; when omitted a folder picker dialog is shown.
    // Returns session info so the renderer can track progress and cancel, or undefined if
    // no database is open or the user cancelled the picker.
    //
    importAssets: (paths?: string[]) => Promise<IImportSession | undefined>;

    //
    // Checks whether ImageMagick and FFmpeg are available on PATH.
    //
    checkTools: () => Promise<IToolsStatus>;

    //
    // Checks whether a database directory exists at the given path.
    //
    checkDatabaseExists: (databasePath: string) => Promise<boolean>;

    //
    // Returns the absolute file system path for a File object obtained from a drag-and-drop event.
    // Required in Electron 30+ where File.path is no longer available in the renderer.
    //
    getPathForFile: (file: File) => string;

    //
    // Starts broadcasting an opaque config object over the local network via UDP + HTTP.
    //
    startDatabaseShare: (config: unknown) => Promise<void>;

    //
    // Stops the active local network database share.
    //
    stopDatabaseShare: () => Promise<void>;

    //
    // Listens for a local network database share broadcast and returns the received config,
    // or null on timeout or cancellation.
    //
    startDatabaseReceive: () => Promise<unknown>;

    //
    // Cancels an in-progress database receive operation.
    //
    cancelDatabaseReceive: () => Promise<void>;
}

