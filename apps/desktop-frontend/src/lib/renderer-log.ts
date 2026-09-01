import type { ILog, ILogDetails } from "utils";
import type { IElectronAPI } from "./electron-ipc";

//
// Renderer log implementation that logs to browser console and forwards to main process.
// This allows all renderer logs to be captured in the log files.
//
class RendererLog implements ILog {
    readonly verboseEnabled: boolean = false;
    private electronAPI: IElectronAPI;

    //
    // Whether something else is already forwarding this renderer's console output to the main
    // process. Test mode patches console.log, console.warn and console.error to do exactly that, so
    // when it is on, writing to the console here as well puts every message into app.log twice: once
    // as the patched console's info line and once as this class's own IPC line at its real level.
    //
    // A duplicate line there is not cosmetic. wait_for_log in the smoke tests keeps a cursor and
    // moves it on by one line per match, so a second wait for the same pattern is answered at once by
    // the previous event's second copy, and the test carries on before the thing it was waiting for
    // has happened. That is what made Electron test 35 press the source cleanup button a third time
    // after a count had turned it into "Delete 1 photo(s)", and it deleted the file the test was
    // about to check was still there.
    //
    private consoleAlreadyForwarded: boolean;

    constructor(electronAPI: IElectronAPI, consoleAlreadyForwarded: boolean) {
        this.electronAPI = electronAPI;
        this.consoleAlreadyForwarded = consoleAlreadyForwarded;
    }

    //
    // Writes to the browser console, unless something else is already forwarding the console to the
    // main process, in which case this message would reach the log twice.
    //
    private writeToConsole(write: (message: string) => void, message: string): void {
        if (this.consoleAlreadyForwarded) {
            return;
        }
        write(message);
    }

    info(message: string): void {
        this.writeToConsole(text => console.log(text), message);
        this.electronAPI.log({
            level: 'info',
            message,
        });
    }

    verbose(message: string): void {
        if (this.verboseEnabled) {
            this.writeToConsole(text => console.log(text), message);
            this.electronAPI.log({
                level: 'verbose',
                message,
            });
        }
    }

    error(message: string): void {
        this.writeToConsole(text => console.error(text), message);
        this.electronAPI.log({
            level: 'error',
            message,
        });
    }

    exception(message: string, error: Error): void {
        this.writeToConsole(text => console.error(text), message);
        this.writeToConsole(text => console.error(text), String(error.stack || error.message || error));
        this.electronAPI.log({
            level: 'exception',
            message,
            error: error.stack || error.message || String(error),
        });
    }

    warn(message: string): void {
        this.writeToConsole(text => console.warn(text), message);
        this.electronAPI.log({
            level: 'warn',
            message,
        });
    }

    debug(message: string): void {
        this.writeToConsole(text => console.debug(text), message);
        this.electronAPI.log({
            level: 'debug',
            message,
        });
    }

    tool(tool: string, data: { stdout?: string; stderr?: string }): void {
        if (data.stdout) {
            this.writeToConsole(text => console.log(text), `== ${tool} stdout ==\n${data.stdout}`);
        }
        if (data.stderr) {
            this.writeToConsole(text => console.log(text), `== ${tool} stderr ==\n${data.stderr}`);
        }
        this.electronAPI.log({
            level: 'tool',
            message: tool,
            toolData: data,
        });
    }

    event(message: string): void {
        this.writeToConsole(text => console.log(text), `[EVENT] ${message}`);
        this.electronAPI.log({
            level: 'event',
            message,
        });
    }

    //
    // Gets details about the main process log file for inclusion in bug reports.
    // Fetched from the main process on demand, not cached.
    //
    getLogDetails(): Promise<ILogDetails> {
        return this.electronAPI.invoke('get-log-details');
    }
}

//
// Create and initialize the renderer log.
//
// consoleAlreadyForwarded says whether the console has been patched to forward to the main process,
// which test mode does, and which makes this class's own console writes a second copy of everything.
//
export function createRendererLog(electronAPI: IElectronAPI, consoleAlreadyForwarded: boolean): ILog {
    return new RendererLog(electronAPI, consoleAlreadyForwarded);
}
