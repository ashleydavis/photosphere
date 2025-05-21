import { ILog, setLog } from "utils";


export type LogOutputType = "none" | "text" | "json" ;

export interface ILogOptions {
    //
    // Changes the output type.
    //
    output: LogOutputType;

    //
    // Enables verbose logging.
    //
    verbose: boolean;
}

class Log implements ILog {
    constructor(private readonly options: ILogOptions) {
    }

    info(message: string): void {
        if (this.options.output === "none") {
            return;
        }

        console.log(message);
    }
    
    verbose(message: string): void {    
        if (this.options.output === "none" || !this.options.verbose) {
            return;
        }
        
        console.log(message);
    }
    
    error(message: string): void {
        if (this.options.output === "none") {
            return;
        }

        console.error(message);
    }
    
    exception(message: string, error: Error): void {
        if (this.options.output === "none") {
            return;
        }

        console.error(message);
        console.error(error.stack || error.message || error);
    }

    warn(message: string): void {
        if (this.options.output === "none") {
            return;
        }

        console.warn(message);
    }
}

//
// Configure the log based on input.
//
export function configureLog(options: ILogOptions): void {
    setLog(new Log(options));
}