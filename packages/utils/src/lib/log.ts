export interface ILog {
    info(message: string): void;
    verbose(message: string): void;
    error(message: string): void;
    exception(message: string, error: Error): void;
    warn(message: string): void;
    debug(message: string): void;
    tool(tool: string, data: { stdout?: string; stderr?: string }): void;
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
        console.error(error.stack || error.message || error);
    },
    warn(message: string): void {
        console.warn(message);
    },
    debug(message: string): void {
        console.debug(message);
    },

    tool(tool: string, data: { stdout?: string; stderr?: string }): void {
        if (data.stdout) {
            console.log(`== ${tool} stdout ==\n${data.stdout}`);
        }
        if (data.stderr) {
            console.error(`== ${tool} stderr ==\n${data.stderr}`);
        }
    }
};


