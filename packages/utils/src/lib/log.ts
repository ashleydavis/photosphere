export interface ILog {
    info(message: string): void;
    verbose(message: string): void;
    error(message: string): void;
    exception(message: string, error: Error): void;
    warn(message: string): void;
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
        console.log(message);
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
};


