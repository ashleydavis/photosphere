import type { ILog, ILogDetails } from "utils";
import type { IJsonObject, IZiggyBridge } from "ziggy-ui";

//
// Log levels the core's renderer-log channel accepts.
//
export type LogLevel = 'info' | 'verbose' | 'error' | 'exception' | 'warn' | 'debug' | 'tool' | 'event';

//
// External tool output carried by a log message of the 'tool' level.
//
export interface IRendererLogToolData {
    // What the tool wrote to standard output.
    stdout?: string;

    // What the tool wrote to standard error.
    stderr?: string;
}

//
// A log message the page sends to the core on the renderer-log channel.
//
export interface IRendererLogMessage {
    // The log level.
    level: LogLevel;

    // The log message text.
    message: string;

    // Stack trace string, populated for the 'exception' level.
    error?: string;

    // External tool output, populated for the 'tool' level.
    toolData?: IRendererLogToolData;
}

//
// Converts a log message to the JSON object the bridge sends, leaving out every field that has no value.
//
export function rendererLogMessageToJson(logMessage: IRendererLogMessage): IJsonObject {
    const json: IJsonObject = {
        level: logMessage.level,
        message: logMessage.message,
    };
    if (logMessage.error !== undefined) {
        json.error = logMessage.error;
    }
    if (logMessage.toolData !== undefined) {
        const toolData: IJsonObject = {};
        if (logMessage.toolData.stdout !== undefined) {
            toolData.stdout = logMessage.toolData.stdout;
        }
        if (logMessage.toolData.stderr !== undefined) {
            toolData.stderr = logMessage.toolData.stderr;
        }
        json.toolData = toolData;
    }
    return json;
}

//
// The text logged for an error: its stack, led by "name: message" when the stack does not already carry the message. V8 starts a stack
// with the error's name and message, which is what the Electron app's log shows. The system web views Ziggy runs in (JavaScriptCore
// and Blink-less engines) start it with the first frame, so the log would say where an error was thrown and not what it said.
//
export function errorLogText(error: Error): string {
    const stack = error.stack;
    if (!stack) {
        return error.message || String(error);
    }
    if (stack.includes(error.message)) {
        return stack;
    }
    return `${error.name}: ${error.message}\n${stack}`;
}

//
// Sends a log message to the core, which writes it to the log file.
//
export function sendRendererLog(ziggy: IZiggyBridge, logMessage: IRendererLogMessage): void {
    ziggy.send("renderer-log", rendererLogMessageToJson(logMessage));
}

//
// Renderer log implementation that logs to browser console and forwards to the core.
// This allows all page logs to be captured in the log files.
//
class RendererLog implements ILog {
    readonly verboseEnabled: boolean = false;
    private ziggy: IZiggyBridge;

    //
    // Whether something else is already forwarding this page's console output to the core. Test mode
    // patches console.log, console.warn and console.error to do exactly that, so when it is on, writing
    // to the console here as well puts every message into app.log twice: once as the patched console's
    // info line and once as this class's own line at its real level.
    //
    // A duplicate line there is not cosmetic. wait_for_log in the smoke tests keeps a cursor and
    // moves it on by one line per match, so a second wait for the same pattern is answered at once by
    // the previous event's second copy, and the test carries on before the thing it was waiting for
    // has happened.
    //
    private consoleAlreadyForwarded: boolean;

    constructor(ziggy: IZiggyBridge, consoleAlreadyForwarded: boolean) {
        this.ziggy = ziggy;
        this.consoleAlreadyForwarded = consoleAlreadyForwarded;
    }

    //
    // Writes to the browser console, unless something else is already forwarding the console to the
    // core, in which case this message would reach the log twice.
    //
    private writeToConsole(write: (message: string) => void, message: string): void {
        if (this.consoleAlreadyForwarded) {
            return;
        }
        write(message);
    }

    info(message: string): void {
        this.writeToConsole(text => console.log(text), message);
        sendRendererLog(this.ziggy, {
            level: 'info',
            message,
        });
    }

    verbose(message: string): void {
        if (this.verboseEnabled) {
            this.writeToConsole(text => console.log(text), message);
            sendRendererLog(this.ziggy, {
                level: 'verbose',
                message,
            });
        }
    }

    error(message: string): void {
        this.writeToConsole(text => console.error(text), message);
        sendRendererLog(this.ziggy, {
            level: 'error',
            message,
        });
    }

    exception(message: string, error: Error): void {
        this.writeToConsole(text => console.error(text), message);
        this.writeToConsole(text => console.error(text), errorLogText(error));
        sendRendererLog(this.ziggy, {
            level: 'exception',
            message,
            error: errorLogText(error),
        });
    }

    warn(message: string): void {
        this.writeToConsole(text => console.warn(text), message);
        sendRendererLog(this.ziggy, {
            level: 'warn',
            message,
        });
    }

    debug(message: string): void {
        this.writeToConsole(text => console.debug(text), message);
        sendRendererLog(this.ziggy, {
            level: 'debug',
            message,
        });
    }

    tool(tool: string, data: IRendererLogToolData): void {
        if (data.stdout) {
            this.writeToConsole(text => console.log(text), `== ${tool} stdout ==\n${data.stdout}`);
        }
        if (data.stderr) {
            this.writeToConsole(text => console.log(text), `== ${tool} stderr ==\n${data.stderr}`);
        }
        sendRendererLog(this.ziggy, {
            level: 'tool',
            message: tool,
            toolData: data,
        });
    }

    event(message: string): void {
        this.writeToConsole(text => console.log(text), `[EVENT] ${message}`);
        sendRendererLog(this.ziggy, {
            level: 'event',
            message,
        });
    }

    //
    // Gets details about the core's log file for inclusion in bug reports.
    // Fetched from the core on demand, not cached.
    //
    getLogDetails(): Promise<ILogDetails> {
        return this.ziggy.invoke<ILogDetails>('get-log-details', null);
    }
}

//
// Create and initialize the renderer log.
//
// consoleAlreadyForwarded says whether the console has been patched to forward to the core,
// which test mode does, and which makes this class's own console writes a second copy of everything.
//
export function createRendererLog(ziggy: IZiggyBridge, consoleAlreadyForwarded: boolean): ILog {
    return new RendererLog(ziggy, consoleAlreadyForwarded);
}
