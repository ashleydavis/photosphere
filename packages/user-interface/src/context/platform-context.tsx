import React, { ReactNode, createContext, useContext } from "react";

//
// Unsubscribe function type for event listeners.
//
export type Unsubscribe = () => void;


//
// Payload for the show-notification IPC event sent from the main process.
//
export interface IShowNotificationData {
    //
    // The message to display in the toast.
    //
    message: string;

    //
    // Color variant of the toast.
    //
    color: 'success' | 'warning' | 'danger' | 'neutral';

    //
    // Duration in milliseconds before auto-dismiss. 0 means no auto-dismiss.
    //
    duration?: number;

    //
    // Optional folder path. When present the toast displays an "Open Folder" action button.
    //
    folderPath?: string;
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
// Platform-specific operations interface.
// Implemented by Electron for desktop and Capacitor for mobile.
//
export interface IPlatformContext {
    //
    // Opens a database file dialog.
    // The selected database path will be sent via the database-opened event.
    //
    openDatabase: () => Promise<void>;

    //
    // Shows a directory picker, creates a new empty database there, and
    // sends the result via the database-opened event.
    //
    createDatabase: () => Promise<void>;

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
    // Subscribes to a named menu action sent from the main process (excluding theme changes).
    // Returns an unsubscribe function.
    //
    onMenuAction: (action: string, callback: () => void) => Unsubscribe;

    //
    // Notifies the platform that the user has edited the database.
    // Used to trigger a debounced background sync.
    //
    notifyDatabaseEdited: () => void;

    //
    // Downloads a single asset to the local filesystem.
    // On Electron, shows a save dialog and streams from the database.
    // On web, fetches the blob and triggers a browser download.
    //
    downloadAsset: (assetId: string, assetType: string, filename: string, contentType: string, databasePath: string) => Promise<void>;

    //
    // Downloads multiple assets to the local filesystem.
    // On Electron, shows a folder picker once then saves all files into it automatically.
    // On web, triggers a browser download for each asset.
    //
    downloadAssets: (assets: IDownloadAssetItem[], databasePath: string) => Promise<void>;

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
    // Opens the given folder path in the system's file manager.
    //
    openFolder: (folderPath: string) => Promise<void>;
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

