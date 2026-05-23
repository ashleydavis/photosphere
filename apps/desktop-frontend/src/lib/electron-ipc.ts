//
// Log levels supported by the renderer-to-main log forwarding bridge.
//
export type LogLevel = 'info' | 'verbose' | 'error' | 'exception' | 'warn' | 'debug' | 'tool' | 'event';

//
// Log message structure sent from renderer to main process over the log() IPC bridge.
//
export interface IRendererLogMessage {
    // The log level.
    level: LogLevel;

    // The log message text.
    message: string;

    // Stack trace string, populated for the 'exception' level.
    error?: string;

    // External tool output, populated for the 'tool' level.
    toolData?: { stdout?: string; stderr?: string };
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
