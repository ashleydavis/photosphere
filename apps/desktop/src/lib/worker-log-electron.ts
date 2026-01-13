import type { ILog } from "utils";

//
// Post message function for Electron utility process
//
const parentPort = (process as any).parentPort;
if (!parentPort) {
    throw new Error('parentPort not available - this must run in an Electron utility process');
}

//
// Log message types sent from worker to main process
//
export interface IWorkerLogMessage {
    type: "log";
    level: "info" | "verbose" | "error" | "exception" | "warn" | "debug" | "tool";
    message: string;
    error?: string; // For exception level
    toolData?: { stdout?: string; stderr?: string }; // For tool level
}

//
// Electron utility process log implementation.
// Sends log messages to the main process via IPC.
//
class WorkerLogElectron implements ILog {
    readonly verboseEnabled: boolean;
    private readonly toolsEnabled: boolean;

    constructor(verboseEnabled: boolean = false, toolsEnabled: boolean = false) {
        this.verboseEnabled = verboseEnabled;
        this.toolsEnabled = toolsEnabled;
    }

    private sendLog(level: IWorkerLogMessage["level"], message: string, error?: string, toolData?: { stdout?: string; stderr?: string }): void {
        const logMessage: IWorkerLogMessage = {
            type: "log",
            level,
            message,
        };

        if (error) {
            logMessage.error = error;
        }

        if (toolData) {
            logMessage.toolData = toolData;
        }

        parentPort.postMessage(logMessage);
    }

    info(message: string): void {
        this.sendLog("info", message);
    }

    verbose(message: string): void {
        if (this.verboseEnabled) {
            this.sendLog("verbose", message);
        }
    }

    error(message: string): void {
        this.sendLog("error", message);
    }

    exception(message: string, error: Error): void {
        this.sendLog("exception", message, error.stack || error.message || String(error));
    }

    warn(message: string): void {
        this.sendLog("warn", message);
    }

    debug(message: string): void {
        this.sendLog("debug", message);
    }

    tool(tool: string, data: { stdout?: string; stderr?: string }): void {
        if (this.toolsEnabled) {
            this.sendLog("tool", tool, undefined, data);
        }
    }
}

//
// Create and export the log instance
//
export function createWorkerLog(verboseEnabled: boolean = false, toolsEnabled: boolean = false): ILog {
    return new WorkerLogElectron(verboseEnabled, toolsEnabled);
}

