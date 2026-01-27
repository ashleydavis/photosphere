import type { ILog } from "utils";
import type { IElectronAPI } from "electron-defs";

//
// Renderer log implementation that logs to browser console and forwards to main process.
// This allows all renderer logs to be captured in the log files.
//
class RendererLog implements ILog {
    readonly verboseEnabled: boolean = false;
    private electronAPI: IElectronAPI;

    constructor(electronAPI: IElectronAPI) {
        this.electronAPI = electronAPI;
    }

    info(message: string): void {
        console.log(message);
        this.electronAPI.log({
            level: 'info',
            message,
        });
    }

    verbose(message: string): void {
        if (this.verboseEnabled) {
            console.log(message);
            this.electronAPI.log({
                level: 'verbose',
                message,
            });
        }
    }

    error(message: string): void {
        console.error(message);
        this.electronAPI.log({
            level: 'error',
            message,
        });
    }

    exception(message: string, error: Error): void {
        console.error(message);
        console.error(error.stack || error.message || error);
        this.electronAPI.log({
            level: 'exception',
            message,
            error: error.stack || error.message || String(error),
        });
    }

    warn(message: string): void {
        console.warn(message);
        this.electronAPI.log({
            level: 'warn',
            message,
        });
    }

    debug(message: string): void {
        console.debug(message);
        this.electronAPI.log({
            level: 'debug',
            message,
        });
    }

    tool(tool: string, data: { stdout?: string; stderr?: string }): void {
        if (data.stdout) {
            console.log(`== ${tool} stdout ==\n${data.stdout}`);
        }
        if (data.stderr) {
            console.log(`== ${tool} stderr ==\n${data.stderr}`);
        }
        this.electronAPI.log({
            level: 'tool',
            message: tool,
            toolData: data,
        });
    }
}

//
// Create and initialize the renderer log
//
export function createRendererLog(electronAPI: IElectronAPI): ILog {
    return new RendererLog(electronAPI);
}
