import React, { ReactNode, createContext, useContext } from "react";
import type { IConflictResolution, ISaveAssetItem } from "api";
import type { NetworkConnectionType } from "../lib/sync-gate";

//
// The current network state reported by a platform. Combines whether the device
// is online with the connection type so the shared sync gate can apply the
// Wi-Fi-only restriction.
//
export interface INetworkStatus {
    //
    // True when the device currently has a network connection.
    //
    connected: boolean;

    //
    // The connection type; "unknown" on platforms that cannot detect it.
    //
    connectionType: NetworkConnectionType;
}

//
// Unsubscribe function type for event listeners.
//
export type Unsubscribe = () => void;

//
// A named UI action pushed from the host (for example a native menu item on
// desktop, or a smoke-test injection). Formerly delivered on its own
// "menu-action" channel; now one kind of platform event.
//
export interface IMenuActionEvent {
    // Discriminant identifying this platform event as a menu action.
    type: "menu-action";

    // The action name for the renderer to dispatch on.
    action: string;
}

//
// Reports that the host developer tools were opened or closed, including via
// their native close button, so the renderer can reflect the real state.
//
export interface IDevToolsStateEvent {
    // Discriminant identifying this platform event as a dev-tools state change.
    type: "devtools-state";

    // True when the developer tools are open.
    open: boolean;
}

//
// A message pushed from the host platform to the renderer. Desktop delivers
// these from the Electron main process; mobile from its native/bridge layer.
// New host-to-renderer messages are added as members of this union so every
// platform shares a single delivery path instead of a channel per message.
//
export type IPlatformEvent =
    | IMenuActionEvent
    | IDevToolsStateEvent;

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
// A shared secret entry stored in the vault.
//
export interface ISharedSecretEntry {
    // The user-typed secret name; this is also the vault key.
    name: string;

    // The category of secret stored (e.g. 's3-credentials', 'encryption-key', 'api-key').
    type: string;
}

//
// A database entry stored in databases.toml.
// The name field is the unique (case-insensitive) identifier for each entry.
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
// A labelled URL used for toast links and CTA actions.
//
export interface IShowNotificationLink {
    //
    // Visible label.
    //
    label: string;

    //
    // External URL opened when the link or action is clicked.
    //
    url: string;
}

//
// Payload for the show-notification IPC event sent from the main process.
//
export interface IShowNotificationData {
    //
    // The message to display in the toast.
    //
    message: string;

    //
    // Color variant of the toast. News items pick their own color via the publisher's
    // `news.yaml` (defaulting to `'primary'` when none is specified); update notifications
    // use `'primary'`.
    //
    color: 'primary' | 'success' | 'warning' | 'danger' | 'neutral';

    //
    // Duration in milliseconds before auto-dismiss. 0 means no auto-dismiss.
    //
    duration?: number;

    //
    // Optional folder path. When present the toast displays an "Open Folder" action button.
    //
    folderPath?: string;

    //
    // Optional inline link rendered in the toast body.
    //
    link?: IShowNotificationLink;

    //
    // Optional CTA action button (URL form). Mutually exclusive with folderPath; if both are
    // present action wins.
    //
    action?: IShowNotificationLink;

    //
    // When present, identifies this toast as a news item. The renderer wires the close
    // button to call `markNewsAsShown(newsId)` so the id is only persisted in
    // `shown_news_ids` after the user actually dismisses the toast.
    //
    newsId?: string;
}

//
// Payload for the update-available IPC event sent from the desktop main process
// when a newer GitHub release is detected. The renderer uses this to render the
// navbar pill and fire a one-off primary-coloured toast.
//
export interface IUpdateAvailableData {
    //
    // The latest available release version (e.g. "1.2.3"), without leading "v".
    //
    latestVersion: string;
}

//
// Identifies a single asset to be downloaded.
//
export interface IDownloadAssetItem {
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

    //
    // The MIME type of the asset.
    //
    contentType: string;
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
// Options for the native folder picker dialog.
//
export interface IPickFolderOptions {
    //
    // Window title shown in the native dialog.
    //
    title?: string;

    //
    // Config key to read the default path from and persist the chosen path back to. The Electron
    // implementation maps this to a key in IDesktopConfig ('lastFolder' is the existing default).
    //
    folderKey?: string;

    //
    // Whether to show the "New Folder" button.
    //
    createDirectory?: boolean;
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
// Platform-specific operations interface.
// Implemented by Electron for desktop and Capacitor for mobile.
//
//
// The outcome of saving downloaded assets, so the caller can surface the right toast.
//
export interface ISaveDownloadResult {
    //
    // "saved" when the files reached the user, "cancelled" when the destination picker or share sheet
    // was dismissed, "failed" when the save did not complete.
    //
    outcome: "saved" | "cancelled" | "failed";

    //
    // How many assets were written successfully.
    //
    savedCount: number;

    //
    // How many assets failed to write (a batch save can partially fail).
    //
    failedCount: number;

    //
    // Error message when outcome is "failed".
    //
    errorMessage?: string;

    //
    // The folder the files were saved into, for the "Open Folder" toast action. Undefined on mobile,
    // where files are handed out via the share sheet.
    //
    savedFolder?: string;
}

export interface IPlatformContext {
    //
    // Opens a database file dialog.
    // The selected database path will be sent via the database-opened event.
    //
    openDatabase: () => Promise<void>;

    //
    // Subscribes to database opened events.
    // Returns an unsubscribe function.
    //
    onDatabaseOpened: (callback: (databasePath: string) => void) => Unsubscribe;

    //
    // Subscribes to database closed events.
    // Returns an unsubscribe function.
    //
    onDatabaseClosed: (callback: () => void) => Unsubscribe;

    //
    // Notifies the platform that the database was opened.
    // This adds the database to recent databases and updates UI state (e.g., menu items in Electron).
    //
    notifyDatabaseOpened: (databasePath: string) => Promise<void>;

    //
    // Notifies the platform that the database was closed.
    // This clears the last database from the config and updates UI state (e.g., menu items in Electron).
    //
    notifyDatabaseClosed: () => Promise<void>;

    //
    // Subscribes to theme changed events.
    // Returns an unsubscribe function.
    //
    onThemeChanged: (callback: (theme: 'light' | 'dark' | 'system') => void) => Unsubscribe;

    //
    // Subscribes to platform events pushed from the host (menu actions,
    // dev-tools state, and future host-to-renderer messages). Delivered from the
    // Electron main process on desktop and from the native/bridge layer on
    // mobile. The callback should switch on `event.type`.
    // Returns an unsubscribe function.
    //
    onPlatformEvent: (callback: (event: IPlatformEvent) => void) => Unsubscribe;

    //
    // Subscribes to navigate events sent from the main process.
    // The page argument is the route to navigate to (e.g. '/gallery', '/databases').
    // Returns an unsubscribe function.
    //
    onNavigate: (callback: (page: string) => void) => Unsubscribe;

    //
    // Notifies the platform that the user has edited the database.
    // Used to trigger a debounced background sync.
    //
    notifyDatabaseEdited: () => void;

    //
    // Copies a blob to the system clipboard.
    //
    copyToClipboard: (blob: Blob, contentType: string) => Promise<void>;


    //
    // Subscribes to sync-started events. Returns an unsubscribe function.
    //
    onSyncStarted: (callback: () => void) => Unsubscribe;

    //
    // Subscribes to sync-completed events. Returns an unsubscribe function.
    //
    onSyncCompleted: (callback: () => void) => Unsubscribe;

    //
    // Subscribes to show-notification events fired from the main process.
    // Returns an unsubscribe function.
    //
    onShowNotification: (callback: (data: IShowNotificationData) => void) => Unsubscribe;

    //
    // Subscribes to databases-changed events fired from the main process when the set of
    // configured databases changes outside of a renderer-initiated mutation (e.g. when a
    // replication completes and registers a new database). The renderer uses this to refresh
    // the Manage Databases list. No-op on web/mobile (which have no main process).
    // Returns an unsubscribe function.
    //
    onDatabasesChanged: (callback: () => void) => Unsubscribe;

    //
    // Subscribes to update-available events fired from the desktop main process when a
    // newer GitHub release is detected and has not already been recorded in news.yaml's
    // `last_shown_update_version`. The renderer uses this to render the navbar pill
    // and fire a one-off primary-coloured toast. No-op on web/mobile (which have no main process
    // and rely on the update check baked into the host app store update flow).
    // Returns an unsubscribe function.
    //
    onUpdateAvailable: (callback: (data: IUpdateAvailableData) => void) => Unsubscribe;

    //
    // Opens the given folder path in the system's file manager.
    //
    openFolder: (folderPath: string) => Promise<void>;

    //
    // Returns the absolute file system path for a File object from a drag-and-drop event.
    // On Electron 30+ this must go through webUtils; on web it is not supported and returns undefined.
    //
    getPathForFile: (file: File) => string | undefined;

    //
    // Whether this platform supports drag-and-drop file/folder import. True on desktop (Electron) and
    // web (browser drag-and-drop); false on mobile, where the import page hides the drop zone and
    // folder button and offers the native photo picker instead.
    //
    supportsDragAndDropImport: boolean;

    //
    // Checks whether ImageMagick and FFmpeg are available on PATH.
    // On web (no-op platform), returns allAvailable: true.
    //
    checkTools: () => Promise<IToolsStatus>;

    //
    // Subscribes to task messages (worker progress events).
    // Returns an unsubscribe function. On web, the handler is never called.
    //
    onTaskMessage: (handler: (taskId: string, message: Record<string, unknown>) => void) => Unsubscribe;

    //
    // Subscribes to task completion events.
    // Returns an unsubscribe function. On web, the handler is never called.
    //
    onTaskComplete: (handler: (taskId: string, result: Record<string, unknown>) => void) => Unsubscribe;

    //
    // Cancels all tasks associated with the given session ID.
    // On web, does nothing.
    //
    cancelTasks: (sessionId: string) => Promise<void>;

    //
    // Returns all configured database entries.
    //
    getDatabases: () => Promise<IDatabaseEntry[]>;

    //
    // Adds a new database entry and returns the created entry.
    //
    addDatabase: (entry: IDatabaseEntry) => Promise<IDatabaseEntry>;

    //
    // Updates an existing database entry. The entry is identified by `originalName`
    // (the entry's name before any rename). If the renamed name collides with another
    // existing entry the call rejects.
    //
    updateDatabase: (originalName: string, entry: IDatabaseEntry) => Promise<void>;

    //
    // Writes the database's origin into its .db/config.json. Pass undefined to clear.
    // This is the canonical source of truth; the entry's cached `origin` is refreshed
    // from here on each open.
    //
    setDatabaseOrigin: (databasePath: string, origin: string | undefined) => Promise<void>;

    //
    // Removes a database entry by name (case-insensitive).
    //
    removeDatabaseEntry: (name: string) => Promise<void>;

    //
    // Returns the database entry whose name matches case-insensitively, or undefined.
    //
    findDatabase: (name: string) => Promise<IDatabaseEntry | undefined>;

    //
    // Opens a directory picker and returns the chosen path, or undefined if cancelled.
    // Accepts optional IPickFolderOptions to control title, default-folder config key, and the
    // "New Folder" button. Calling with no args keeps the default behaviour (title "Select Folder",
    // reads from and persists to 'lastFolder', no "New Folder" button).
    //
    pickFolder: (options?: IPickFolderOptions) => Promise<string | undefined>;

    //
    // Opens a multi-file picker dialog and returns the chosen paths, or undefined if cancelled.
    //
    pickFiles: (title: string) => Promise<string[] | undefined>;

    //
    // Saves downloaded assets to a user-chosen location and hands them to the user, reporting the
    // outcome. The platform owns the whole operation so it can do it in a single native call: desktop
    // shows one dialog (Save-As for one asset, folder picker for several) and writes straight there;
    // mobile writes to app-private storage then hands the files out via the native share sheet. One
    // item is a single download, several is a batch.
    //
    saveDownloadedFiles: (items: ISaveAssetItem[], databasePath: string) => Promise<ISaveDownloadResult>;

    //
    // Returns all shared secrets stored in the vault.
    //
    listSecrets: () => Promise<ISharedSecretEntry[]>;

    //
    // Adds a new shared secret to the vault.
    //
    addSecret: (entry: ISharedSecretEntry, value: string) => Promise<ISharedSecretEntry>;

    //
    // Updates an existing shared secret in the vault.
    // originalName is the prior vault key, used to delete the old entry when the secret is renamed.
    //
    updateSecret: (originalName: string, entry: ISharedSecretEntry, value?: string) => Promise<void>;

    //
    // Deletes a shared secret by name.
    //
    deleteSecret: (name: string) => Promise<void>;

    //
    // Retrieves the raw value string for a shared secret by name.
    //
    getSecretValue: (name: string) => Promise<string | undefined>;

    //
    // Returns the top-5 most recently opened database entries, most recent first.
    //
    getRecentDatabases: () => Promise<IDatabaseEntry[]>;

    //
    // Removes the given name from the recently opened list only; the underlying database entry is preserved.
    //
    removeRecentDatabaseName: (name: string) => Promise<void>;

    //
    // Lists directory names under the given S3 bucket and prefix using the credentials
    // identified by s3Key (a vault secret name).
    //
    listS3Dirs: (s3Key: string, bucket: string, prefix: string) => Promise<string[]>;

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
    importSharePayload: (payload: unknown, conflictResolutions: Record<string, IConflictResolution>) => Promise<void>;

    //
    // Records that the user has dismissed the update-available toast for the given
    // version. Invoked from the toast's onDismiss callback so the version is only
    // persisted after the user clicks the close button. No-op on web/mobile.
    //
    markUpdateAsShown: (version: string) => Promise<void>;

    //
    // Records that the user has dismissed the news toast for the given news item id.
    // Invoked from the toast's onDismiss callback so the id is only persisted after
    // the user clicks the close button. No-op on web/mobile.
    //
    markNewsAsShown: (newsId: string) => Promise<void>;

    //
    // Toggles the developer tools for the current platform. The desktop app
    // opens or closes the native Electron dev tools; the web and mobile apps
    // show or hide an in-page console. The shared UI calls this without knowing
    // which inspector is used.
    //
    toggleDevTools: () => void;

    //
    // Returns the current network status (online state and connection type).
    // Desktop and web report connectionType "unknown"; mobile reports the real
    // type once native network detection is wired up.
    //
    getNetworkStatus: () => Promise<INetworkStatus>;

    //
    // Subscribes to network status changes. The callback fires whenever the
    // device goes online/offline (or, on mobile, the connection type changes).
    // Returns an unsubscribe function.
    //
    onNetworkStatusChange: (callback: (status: INetworkStatus) => void) => Unsubscribe;

    //
    // Pushes the shared sync gate's decision to the host scheduler. When false
    // the host must not enqueue automatic syncs. Computed by the shared
    // SyncContext from the user toggles and the current network status.
    //
    setSyncAllowed: (allowed: boolean) => void;
}

const PlatformContext = createContext<IPlatformContext | undefined>(undefined);

export interface IPlatformContextProviderProps {
    children: ReactNode | ReactNode[];
    value: IPlatformContext;
}

//
// Platform context provider.
// Should be implemented by platform-specific code (Electron, Capacitor, etc.)
//
export function PlatformContextProvider({ children, value }: IPlatformContextProviderProps) {
    return (
        <PlatformContext.Provider value={value}>
            {children}
        </PlatformContext.Provider>
    );
}

//
// Get the platform context.
//
export function usePlatform(): IPlatformContext {
    const context = useContext(PlatformContext);
    if (!context) {
        throw new Error(`PlatformContext is not set! Add PlatformContextProvider to the component tree.`);
    }
    return context;
}

