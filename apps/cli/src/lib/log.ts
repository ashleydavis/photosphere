import { ILog, ILogDetails, noLogDetails, setLog, formatErrorChain } from "utils";
import { FileLogger } from "./file-logger";
import { writeErrorLine, writeOutputLine } from "./console-output";

export interface ILogOptions {
    //
    // Enables verbose logging.
    //
    verbose?: boolean;

    //
    // Enables debug logging.
    //
    debug?: boolean;

    //
    // Enables tool output logging.
    //
    tools?: boolean;

    //
    // Disables file logging (console only)
    //
    disableFileLogging?: boolean;
}

//
// Global reference to the file logger for access from other modules
//
let fileLogger: FileLogger | undefined;

class Log implements ILog {
    constructor(private readonly options: ILogOptions) {
    }

    get verboseEnabled(): boolean {
        return this.options.verbose || false;
    }

    info(message: string): void {
        writeOutputLine(message);
    }

    verbose(message: string): void {
        if (!this.options.verbose) {
            return;
        }

        writeOutputLine(message);
    }

    error(message: string): void {
        writeErrorLine(message);
    }

    exception(message: string, error: Error): void {
        writeErrorLine(message);
        writeErrorLine(formatErrorChain(error));
    }

    warn(message: string): void {
        writeErrorLine(message);
    }

    debug(message: string): void {
        if (!this.options.debug) {
            return;
        }

        writeErrorLine(message);
    }

    tool(tool: string, data: { stdout?: string; stderr?: string }): void {
        if (!this.options.tools) {
            return;
        }

        if (data.stdout) {
            writeOutputLine(`== ${tool} stdout ==\n${data.stdout}`);
        }
        if (data.stderr) {
            writeOutputLine(`== ${tool} stderr ==\n${data.stderr}`);
        }
    }

    event(message: string): void {
        writeOutputLine(`[EVENT] ${message}`);
    }

    //
    // Gets details about the active log file for inclusion in bug reports.
    // The console logger has no log file.
    //
    getLogDetails(): Promise<ILogDetails> {
        return Promise.resolve(noLogDetails);
    }
}

//
// Configure the log based on input.
//
export async function configureLog(options: ILogOptions): Promise<void> {
    const consoleLogger = new Log(options);
    setLog(consoleLogger); // Set the console logger before trying to create the file logger, just in case we need the log!
    
    if (!options.disableFileLogging) {
        const command = process.argv.slice(2).join(' ') || 'unknown';
        fileLogger = await FileLogger.create(consoleLogger, command);
        setLog(fileLogger);
    }
}

//
// Get the current file logger instance
//
export function getFileLogger(): FileLogger | undefined {
    return fileLogger;
}