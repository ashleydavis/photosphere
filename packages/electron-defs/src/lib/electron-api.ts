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
    
    // Logging methods - forward logs from renderer to main process for file logging
    log: (message: IRendererLogMessage) => void;
}

