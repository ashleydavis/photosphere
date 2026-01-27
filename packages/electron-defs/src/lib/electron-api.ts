//
// Type definition for Electron API exposed via preload script
// Shared between desktop main process and desktop frontend
//
export interface IElectronAPI {
    addTask: (taskType: string, data: any, taskId?: string) => void;
    onMessage: (messageType: string, callback: (data: any) => void) => void;
    removeAllListeners: (messageType: string) => void;
    openDatabase: () => Promise<void>;
    getRecentDatabases: () => Promise<string[]>;
    removeDatabase: (databasePath: string) => Promise<void>;
    notifyDatabaseOpened: (databasePath: string) => Promise<void>;
    notifyDatabaseClosed: () => Promise<void>;
    getTheme: () => Promise<'light' | 'dark' | 'system'>;
    setTheme: (theme: 'light' | 'dark' | 'system') => Promise<void>;
}

