import { ILog, setLog } from "utils";

export interface ILogOptions {
    //
    // Enables verbose logging.
    //
    verbose?: boolean;

    //
    // Enables debug logging.
    //
    debug?: boolean;
}

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
export function configureLog(options: ILogOptions): void {
    setLog(new Log(options));
}