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
// Generic Electron IPC bridge exposed by the preload script.
// Use invoke() for async request/response, send() for fire-and-forget,
// on()/off() to subscribe and unsubscribe from main-process events.
// New IPC channels can be added without modifying this interface.
//
export interface IElectronAPI {
    //
    // Sends a request to the main process on the given channel and returns a promise
    // that resolves with the response.
    //
    invoke(channel: string, data?: any): Promise<any>;

    //
    // Sends a fire-and-forget message to the main process on the given channel.
    //
    send(channel: string, data?: any): void;

    //
    // Registers a callback invoked whenever the main process sends a message on the given channel.
    //
    onMessage(channel: string, callback: (data: any) => void): void;

    //
    // Removes all listeners registered for the given channel.
    //
    removeAllListeners(channel: string): void;

    //
    // Forwards a log message to the main process for file logging.
    //
    log(message: IRendererLogMessage): void;

    //
    // Returns the absolute file system path for a File object obtained from a drag-and-drop event.
    // Required in Electron 30+ where File.path is no longer available in the renderer.
    //
    getPathForFile(file: File): string;
}
