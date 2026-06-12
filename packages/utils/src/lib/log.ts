import { formatErrorChain } from "./wrapped-error";

//
// Details about the active log file, used to pre-fill bug reports.
//
export interface ILogDetails {
    // Full path to the active log file, or null when file logging is not active.
    logFilePath: string | null;

    // The header section of the active log file (system information), or a placeholder when unavailable.
    logHeader: string;
}

//
// Log details placeholder for log implementations that do not write to a log file.
//
export const noLogDetails: ILogDetails = {
    logFilePath: null,
    logHeader: "No log file available",
};

export interface ILog {
    info(message: string): void;
    verbose(message: string): void;
    error(message: string): void;
    exception(message: string, error: Error): void;
    warn(message: string): void;
    debug(message: string): void;
    tool(tool: string, data: { stdout?: string; stderr?: string }): void;
    event(message: string): void;
    verboseEnabled: boolean;

    // Gets details about the active log file for inclusion in bug reports.
    getLogDetails(): Promise<ILogDetails>;
}

//
// Sets the global log.
//
export function setLog(_log: ILog): void {
    log = _log;
}

export let log: ILog = {
    info(message: string): void {
        console.log(message);
    },
    verbose(message: string): void {
        // You have to override this method if you want to use it.
    },
    error(message: string): void {
        console.error(message);
    },
    exception(message: string, error: Error): void {
        console.error(message);
        console.error(formatErrorChain(error));
    },
    warn(message: string): void {
        console.warn(message);
    },
    debug(message: string): void {
        console.debug(message);
    },

    tool(tool: string, data: { stdout?: string; stderr?: string }): void {
        // You have to override this method if you want to use it.
    },

    event(message: string): void {
        console.log(`[EVENT] ${message}`);
    },

    getLogDetails(): Promise<ILogDetails> {
        return Promise.resolve(noLogDetails);
    },

    verboseEnabled: false
};


