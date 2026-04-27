//
// A secret stored in the vault, passed over IPC between renderer and main process.
//
export interface IVaultSecret {
    // Unique name that identifies the secret within the vault.
    name: string;

    // Caller-defined category string for the secret (e.g. "api-key", "s3-credentials").
    type: string;

    // The secret value as a plain string; callers serialise structured values as JSON.
    value: string;
}

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
    // The vault key name for this secret.
    id: string;

    // Human-readable display name chosen by the user (the "label" field in the vault value JSON).
    name: string;

    // The category of secret stored (e.g. 's3-credentials', 'encryption-key', 'api-key').
    type: string;
}

//
// A database entry stored in databases.json.
// The path field is the unique identifier for each entry.
//
export interface IDatabaseEntry {
    // Human-readable display name.
    name: string;

    // Optional description of this database.
    description: string;

    // Absolute filesystem path (or S3 path) to the database directory.
    path: string;

    // Optional origin string read from .db/config.json; refreshed each time the database is opened.
    origin?: string;

    // Vault secret name for S3 credentials.
    s3Key?: string;

    // Vault secret name for the encryption key pair.
    encryptionKey?: string;

    // Vault secret name for the geocoding API key.
    geocodingKey?: string;
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
    // Returns all configured database entries from desktop.json.
    //
    getDatabases: () => Promise<IDatabaseEntry[]>;

    //
    // Adds a new database entry and returns the created entry.
    //
    addDatabase: (entry: IDatabaseEntry) => Promise<IDatabaseEntry>;

    //
    // Updates an existing database entry (matched by path).
    //
    updateDatabase: (entry: IDatabaseEntry) => Promise<void>;

    //
    // Removes a database entry by path.
    //
    removeDatabaseEntry: (path: string) => Promise<void>;

    //
    // Opens a directory picker dialog and returns the chosen path, or undefined if cancelled.
    //
    pickFolder: () => Promise<string | undefined>;

    //
    // Retrieves a vault secret by name; returns undefined if not found.
    //
    vaultGet: (name: string) => Promise<IVaultSecret | undefined>;

    //
    // Creates or overwrites a vault secret.
    //
    vaultSet: (secret: IVaultSecret) => Promise<void>;

    //
    // Deletes a vault secret by name; does nothing if it does not exist.
    //
    vaultDelete: (name: string) => Promise<void>;

    //
    // Returns all secrets stored in the vault.
    //
    vaultList: () => Promise<IVaultSecret[]>;

    //
    // Creates a database at the given path (no file picker) and sends database-opened to renderer.
    //
    createDatabaseAtPath: (path: string) => Promise<void>;

    //
    // Lists directory names under the given S3 bucket and prefix using the credentials
    // identified by credentialId (a shared secret id).
    //
    listS3Dirs: (credentialId: string, bucket: string, prefix: string) => Promise<string[]>;

    //
    // Returns the top-5 most recently opened database entries, most recent first.
    //
    getRecentDatabases: () => Promise<IDatabaseEntry[]>;

    //
    // Starts a share receiver using the caller-supplied pairing code (generated by the sender).
    //
    startShareReceive: (code: string) => Promise<void>;

    //
    // Waits for a sender to deliver a payload to the active receiver.
    // Returns the payload on success, or null on timeout.
    //
    waitShareReceive: () => Promise<unknown>;

    //
    // Cancels the active share receiver.
    //
    cancelShareReceive: () => Promise<void>;

    //
    // Creates a sender with the given payload and pairing code, then waits for a receiver on the LAN.
    // Returns the discovered endpoint, or null on timeout.
    //
    waitForReceiver: (payload: unknown, code: string) => Promise<unknown>;

    //
    // Sends the payload to the discovered receiver. The sender uses the code it was constructed with.
    // Returns true on success, false if the code was rejected.
    //
    sendToReceiver: (endpoint: unknown) => Promise<boolean>;

    //
    // Cancels the active share sender.
    //
    cancelShareSend: () => Promise<void>;

    //
    // Imports a share payload (database or secret) into the local vault and config.
    // conflictResolutions maps each incoming secret name to its resolution when that
    // name already exists in the vault on this device.
    //
    importSharePayload: (payload: unknown, conflictResolutions: unknown) => Promise<void>;
}

