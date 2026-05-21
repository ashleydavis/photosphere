import type { ISecret } from 'vault';
import type { IDatabaseEntry } from 'node-api';
export type { IDatabaseEntry };

//
// S3 credentials for accessing an S3-compatible object store.
//
export interface IS3Credentials {
    // AWS region (e.g. "us-east-1").
    region: string;

    // Access key ID for authentication.
    accessKeyId: string;

    // Secret access key for authentication.
    secretAccessKey: string;

    // Optional custom endpoint URL (for non-AWS S3-compatible services).
    endpoint?: string;
}

//
// An RSA key pair stored as PEM strings.
//
export interface IEncryptionKeyPair {
    // PEM-encoded PKCS#8 private key.
    privateKeyPem: string;

    // PEM-encoded SPKI public key.
    publicKeyPem: string;
}

//
// All secrets associated with a database entry (all fields optional — absent means not configured).
//
export interface IDatabaseSecrets {
    // S3 credentials for this database.
    s3Credentials?: IS3Credentials;

    // RSA key pair used to encrypt/decrypt assets.
    encryptionKeyPair?: IEncryptionKeyPair;

    // Google geocoding API key.
    geocodingApiKey?: string;
}

//
// A shared secret entry stored in the vault.
//
export interface ISharedSecretEntry {
    // The user-typed secret name; this is also the vault key.
    name: string;

    // The category of secret stored (e.g. 's3-credentials', 'encryption-key', 'api-key').
    type: string;
}


//
// Log levels supported by the logging system
//
export type LogLevel = 'info' | 'verbose' | 'error' | 'exception' | 'warn' | 'debug' | 'tool' | 'event';

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
    //
    // Enqueues a background task of the given type with the supplied data, tagged with a source
    // string (used for bulk cancellation) and an optional explicit task ID.
    //
    addTask(taskType: string, data: any, source: string, taskId?: string): void;

    //
    // Cancels all background tasks whose source tag matches the given value.
    //
    cancelTasks(source: string): void;

    //
    // Registers a callback invoked whenever an IPC message of the given type arrives from the main process.
    //
    onMessage(messageType: string, callback: (data: any) => void): void;

    //
    // Removes all IPC message listeners registered for the given message type.
    //
    removeAllListeners(messageType: string): void;

    //
    // Opens a folder-picker dialog and loads the selected database.
    //
    openDatabase(): Promise<void>;

    //
    // Opens a folder-picker dialog and creates a new database at the selected location.
    //
    createDatabase(): Promise<void>;

    //
    // Unregisters the database at the given path; does not delete files on disk.
    //
    removeDatabase(databasePath: string): Promise<void>;

    //
    // Notifies the main process that a database at the given path has been opened.
    //
    notifyDatabaseOpened(databasePath: string): Promise<void>;

    //
    // Notifies the main process that the currently open database has been closed.
    //
    notifyDatabaseClosed(): Promise<void>;

    //
    // Retrieves a persisted config value by key; returns undefined if the key is not set.
    //
    getConfig(key: string): Promise<any | undefined>;

    //
    // Persists a config value under the given key.
    //
    setConfig(key: string, value: unknown): Promise<void>;

    //
    // Notifies the main process that the database was edited.
    // The main process debounces this signal and triggers a background sync.
    //
    notifyDatabaseEdited(): void;

    //
    // Forwards a log message from the renderer to the main process for file logging.
    //
    log(message: IRendererLogMessage): void;

    //
    // Sends an FPS measurement to the main process for writing to a log file.
    //
    sendFps(fps: number): void;

    //
    // Opens a save dialog and, if confirmed, enqueues a background task to stream the asset to the chosen file.
    //
    saveAsset(assetId: string, assetType: string, filename: string, databasePath: string): Promise<void>;

    //
    // Opens a folder picker and, if confirmed, enqueues background tasks to save all assets into it.
    //
    saveAssets(assets: ISaveAssetItem[], databasePath: string): Promise<void>;

    //
    // Opens the given path in the system's file manager.
    //
    openPath(path: string): Promise<void>;

    //
    // Imports the given paths (files or directories) into the current database.
    // When paths is provided they are used directly; when omitted a directory picker dialog is shown.
    // Returns session info so the renderer can track progress and cancel, or undefined if
    // no database is open or the user cancelled the picker.
    //
    importDirectories(paths?: string[]): Promise<IImportSession | undefined>;

    //
    // When paths is provided they are used directly; when omitted a multi-file picker dialog is shown.
    // Returns session info so the renderer can track progress and cancel, or undefined if
    // no database is open or the user cancelled the picker.
    //
    importFiles(paths?: string[]): Promise<IImportSession | undefined>;

    //
    // Checks whether ImageMagick and FFmpeg are available on PATH.
    //
    checkTools(): Promise<IToolsStatus>;

    //
    // Checks whether a database directory exists at the given path.
    //
    checkDatabaseExists(databasePath: string): Promise<boolean>;

    //
    // Returns the absolute file system path for a File object obtained from a drag-and-drop event.
    // Required in Electron 30+ where File.path is no longer available in the renderer.
    //
    getPathForFile(file: File): string;

    //
    // Returns all configured database entries from desktop.json.
    //
    getDatabases(): Promise<IDatabaseEntry[]>;

    //
    // Adds a new database entry and returns the created entry.
    //
    addDatabase(entry: IDatabaseEntry): Promise<IDatabaseEntry>;

    //
    // Updates an existing database entry. The entry is identified by `originalName`
    // (the entry's name before any rename). The call rejects if the renamed name
    // collides with another existing entry.
    //
    updateDatabase(originalName: string, entry: IDatabaseEntry): Promise<void>;

    //
    // Removes a database entry by name (case-insensitive).
    //
    removeDatabaseEntry(name: string): Promise<void>;

    //
    // Returns the database entry whose name matches case-insensitively, or undefined.
    //
    findDatabase(name: string): Promise<IDatabaseEntry | undefined>;

    //
    // Opens a directory picker dialog and returns the chosen path, or undefined if cancelled.
    //
    pickFolder(): Promise<string | undefined>;

    //
    // Retrieves a vault secret by name; returns undefined if not found.
    //
    vaultGet(name: string): Promise<ISecret | undefined>;

    //
    // Creates or overwrites a vault secret.
    //
    vaultSet(secret: ISecret): Promise<void>;

    //
    // Deletes a vault secret by name; does nothing if it does not exist.
    //
    vaultDelete(name: string): Promise<void>;

    //
    // Returns all secrets stored in the vault.
    //
    vaultList(): Promise<ISecret[]>;

    //
    // Creates a database at the given path (no file picker) and sends database-opened to renderer.
    //
    createDatabaseAtPath(path: string): Promise<void>;

    //
    // Lists directory names under the given S3 bucket and prefix using the credentials
    // identified by s3Key (a vault secret name).
    //
    listS3Dirs(s3Key: string, bucket: string, prefix: string): Promise<string[]>;

    //
    // Returns the top-5 most recently opened database entries, most recent first.
    //
    getRecentDatabases(): Promise<IDatabaseEntry[]>;

    //
    // Removes a name from the recently opened list only; the database entry itself is preserved.
    //
    removeRecentDatabaseName(name: string): Promise<void>;

    //
    // Starts a share receiver using the caller-supplied pairing code (generated by the sender).
    //
    startShareReceive(code: string): Promise<void>;

    //
    // Waits for a sender to deliver a payload to the active receiver.
    // Returns the payload on success, or null on timeout.
    //
    waitShareReceive(): Promise<unknown>;

    //
    // Cancels the active share receiver.
    //
    cancelShareReceive(): Promise<void>;

    //
    // Creates a sender with the given payload and pairing code, then waits for a receiver on the LAN.
    // Returns the discovered endpoint, or null on timeout.
    //
    waitForReceiver(payload: unknown, code: string): Promise<unknown>;

    //
    // Sends the payload to the discovered receiver. The sender uses the code it was constructed with.
    // Returns true on success, false if the code was rejected.
    //
    sendToReceiver(endpoint: unknown): Promise<boolean>;

    //
    // Cancels the active share sender.
    //
    cancelShareSend(): Promise<void>;

    //
    // Imports a share payload (database or secret) into the local vault and config.
    // conflictResolutions maps each incoming secret name to its resolution when that
    // name already exists in the vault on this device.
    //
    importSharePayload(payload: unknown, conflictResolutions: unknown): Promise<void>;

    //
    // Records that the user has dismissed the update-available toast for the given
    // version. Persists the version in news.yaml's `last_shown_update_version` so the
    // notification is not re-fired on subsequent startups until a newer version is
    // released. Called only when the user clicks the close button on the toast.
    //
    markUpdateShown(version: string): Promise<void>;

    //
    // Records that the user has dismissed the news toast for the given news item id.
    // Persists the id in news.yaml's `shown_news_ids` so the item is not re-shown on
    // subsequent startups. Called only when the user clicks the close button.
    //
    markNewsShown(newsId: string): Promise<void>;
}

