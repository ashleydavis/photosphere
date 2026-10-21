import type { ITestCommandPayload, ITestTransport } from "user-interface";
import type { IJsonObject, IZiggyBridge } from "ziggy-ui";
import type { LogLevel } from "./renderer-log";
import { sendRendererLog } from "./renderer-log";

//
// The test commands the shared test driver would accept but that cannot work on Ziggy, each with the reason. They stage the
// answer to a native dialog by a window event that nothing on Ziggy listens for, so letting the driver dispatch it would report
// success for a command that did nothing. A test answers a native dialog with the control connection's pick-answer command.
//
const unsupportedCommands: Map<string, string> = new Map([
    ["pick-files", "The native file picker is answered with the control connection's pick-answer command on Ziggy."],
    ["stage-pick-folder", "The native folder picker is answered with the control connection's pick-answer command on Ziggy."],
    ["stage-delete", "The photo library's delete confirmation cannot be answered from the page on Ziggy."],
]);

//
// The command a test sends, as the core forwards it: the name in `command` and its arguments beside it.
//
export interface ITestCommandBody extends ITestCommandPayload {
    // What to do: click, type, get-value, navigate and the rest the shared test driver performs.
    command: string;
}

//
// A test-command event from the core.
//
export interface ITestCommandEvent {
    // Identifies the command so its answer reaches the connection that is waiting for it.
    requestId: number;

    // The command to perform.
    command: ITestCommandBody;
}

//
// What the page answers a command with, on the test-result channel.
//
export interface ITestCommandResult {
    // Whether the command did what it was asked.
    ok: boolean;

    // The value read, for get-value and get-storage.
    value?: string;

    // Why the command failed, when it did.
    error?: string;
}

//
// Performs one command and gives the result to send back. The ready command is answered here. A command that cannot work on
// Ziggy, and a command the driver rejects, are failures with a reason, never a silent success.
//
export async function answerTestCommand(handler: (command: string, payload: ITestCommandPayload) => Promise<string | undefined>, body: ITestCommandBody): Promise<ITestCommandResult> {
    if (body.command === "ready") {
        return { ok: true };
    }
    const unsupportedReason = unsupportedCommands.get(body.command);
    if (unsupportedReason !== undefined) {
        return {
            ok: false,
            error: unsupportedReason,
        };
    }
    try {
        const value = await handler(body.command, body);
        if (value === undefined) {
            return { ok: true };
        }
        return {
            ok: true,
            value,
        };
    }
    catch (error) {
        return {
            ok: false,
            error: error instanceof Error ? error.message : String(error),
        };
    }
}

//
// Converts a result to the JSON the page sends on the test-result channel. A field with no value is left out.
//
export function testCommandResultToJson(result: ITestCommandResult): IJsonObject {
    const json: IJsonObject = { ok: result.ok };
    if (result.value !== undefined) {
        json.value = result.value;
    }
    if (result.error !== undefined) {
        json.error = result.error;
    }
    return json;
}

//
// The log levels the shared test driver reports lines at, mapped to the levels the core accepts. A level the core has no name
// for throws.
//
export function toLogLevel(level: string): LogLevel {
    switch (level) {
        case "info":
        case "verbose":
        case "error":
        case "exception":
        case "warn":
        case "debug":
        case "tool":
        case "event":
            return level;
        default:
            throw new Error(`The test driver logged at the level "${level}", which the core does not know.`);
    }
}

//
// A test transport for the shared test driver over the core's test-command events. Each command arrives as a test-command event,
// is performed by the driver's handler and is answered with sendTestResult and the request id it came with.
//
export function createZiggyTestTransport(ziggy: IZiggyBridge): ITestTransport {
    return {
        onCommand(handler: (command: string, payload: ITestCommandPayload) => Promise<string | undefined>): void {
            ziggy.onTestCommand<ITestCommandBody>(event => {
                answerTestCommand(handler, event.command)
                    .then(result => ziggy.sendTestResult(event.requestId, testCommandResultToJson(result)));
            });
        },

        sendLog(level: string, message: string): void {
            sendRendererLog(ziggy, {
                level: toLogLevel(level),
                message,
            });
        },
    };
}

//
// Tells the core the page is listening for test commands, so it can start sending them. Called once everything a command can
// reach is in place.
//
export function signalTestPageReady(ziggy: IZiggyBridge): void {
    ziggy.testUiReady();
}
