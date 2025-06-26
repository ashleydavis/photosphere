import { ILog, setLog } from "utils";
import { FileLogger } from "./file-logger";

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

    info(message: string): void {
        console.log(message);
    }
    
    verbose(message: string): void {    
        if (!this.options.verbose) {
            return;
        }
        
        console.log(message);
    }
    
    error(message: string): void {
        console.error(message);
    }
    
    exception(message: string, error: Error): void {
        console.error(message);
        console.error(error.stack || error.message || error);
    }

    warn(message: string): void {
        console.warn(message);
    }

    debug(message: string): void {
        if (!this.options.debug) {
            return;
        }

        console.debug(message);
    }

    tool(tool: string, data: { stdout?: string; stderr?: string }): void {
        if (data.stdout) {
            this.verbose(`== ${tool} stdout ==\n${data.stdout}`);
        }
        if (data.stderr) {
            this.verbose(`== ${tool} stderr ==\n${data.stderr}`);
        }
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