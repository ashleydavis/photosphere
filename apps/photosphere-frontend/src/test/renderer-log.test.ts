import { createRendererLog, errorLogText, rendererLogMessageToJson } from '../lib/renderer-log';
import { FakeZiggy } from './fake-ziggy';

describe("createRendererLog", () => {

    let consoleLog: jest.SpyInstance;
    let consoleError: jest.SpyInstance;
    let consoleWarn: jest.SpyInstance;

    beforeEach(() => {
        consoleLog = jest.spyOn(console, 'log').mockImplementation(() => {});
        consoleError = jest.spyOn(console, 'error').mockImplementation(() => {});
        consoleWarn = jest.spyOn(console, 'warn').mockImplementation(() => {});
    });

    afterEach(() => {
        consoleLog.mockRestore();
        consoleError.mockRestore();
        consoleWarn.mockRestore();
    });

    test("writes to the console and forwards when nothing else forwards the console", () => {
        const ziggy = new FakeZiggy();
        const log = createRendererLog(ziggy, false);

        log.info("hello");

        expect(consoleLog).toHaveBeenCalledWith("hello");
        expect(ziggy.sent).toEqual([{ name: 'renderer-log', data: { level: 'info', message: "hello" } }]);
    });

    // The whole point of the flag: test mode patches the console to forward to the core, so a
    // console write here would put the message into app.log a second time, and a duplicate line there
    // answers the next wait_for_log before the event it is waiting for has happened.
    test("does not write to the console when the console is already forwarded", () => {
        const ziggy = new FakeZiggy();
        const log = createRendererLog(ziggy, true);

        log.info("hello");

        expect(consoleLog).not.toHaveBeenCalled();
        expect(ziggy.sent).toEqual([{ name: 'renderer-log', data: { level: 'info', message: "hello" } }]);
    });

    test("forwards an event without writing it to the console when the console is already forwarded", () => {
        const ziggy = new FakeZiggy();
        const log = createRendererLog(ziggy, true);

        log.event("Source cleanup counted");

        expect(consoleLog).not.toHaveBeenCalled();
        expect(ziggy.sent).toEqual([{ name: 'renderer-log', data: { level: 'event', message: "Source cleanup counted" } }]);
    });

    test("keeps errors and warnings off the console when the console is already forwarded", () => {
        const ziggy = new FakeZiggy();
        const log = createRendererLog(ziggy, true);

        log.error("went wrong");
        log.warn("careful");

        expect(consoleError).not.toHaveBeenCalled();
        expect(consoleWarn).not.toHaveBeenCalled();
        expect(ziggy.sent).toEqual([
            { name: 'renderer-log', data: { level: 'error', message: "went wrong" } },
            { name: 'renderer-log', data: { level: 'warn', message: "careful" } },
        ]);
    });

    test("forwards an exception with its stack", () => {
        const ziggy = new FakeZiggy();
        const log = createRendererLog(ziggy, true);
        const error = new Error("boom");

        log.exception("it failed", error);

        expect(ziggy.sent).toEqual([{ name: 'renderer-log', data: { level: 'exception', message: "it failed", error: error.stack } }]);
    });

    test("forwards tool output", () => {
        const ziggy = new FakeZiggy();
        const log = createRendererLog(ziggy, true);

        log.tool("magick", { stdout: "out" });

        expect(ziggy.sent).toEqual([{ name: 'renderer-log', data: { level: 'tool', message: "magick", toolData: { stdout: "out" } } }]);
    });

    test("writes both streams of tool output to the console when nothing else forwards the console", () => {
        const ziggy = new FakeZiggy();
        const log = createRendererLog(ziggy, false);

        log.tool("magick", { stdout: "out", stderr: "err" });

        expect(consoleLog).toHaveBeenCalledWith("== magick stdout ==\nout");
        expect(consoleLog).toHaveBeenCalledWith("== magick stderr ==\nerr");
        expect(ziggy.sent).toEqual([{ name: 'renderer-log', data: { level: 'tool', message: "magick", toolData: { stdout: "out", stderr: "err" } } }]);
    });

    test("writes a debug message to the console and forwards it", () => {
        const consoleDebug = jest.spyOn(console, 'debug').mockImplementation(() => {});
        try {
            const ziggy = new FakeZiggy();
            const log = createRendererLog(ziggy, false);

            log.debug("details");

            expect(consoleDebug).toHaveBeenCalledWith("details");
            expect(ziggy.sent).toEqual([{ name: 'renderer-log', data: { level: 'debug', message: "details" } }]);
        }
        finally {
            consoleDebug.mockRestore();
        }
    });

    test("does not forward verbose messages, which are off", () => {
        const ziggy = new FakeZiggy();
        const log = createRendererLog(ziggy, false);

        log.verbose("noise");

        expect(ziggy.sent).toEqual([]);
    });

    test("fetches the log details from the core on demand", async () => {
        const ziggy = new FakeZiggy();
        ziggy.replies.set('get-log-details', { logFilePath: "/logs/photosphere.log", logHeader: "header" });
        const log = createRendererLog(ziggy, false);

        const details = await log.getLogDetails();

        expect(details).toEqual({ logFilePath: "/logs/photosphere.log", logHeader: "header" });
        expect(ziggy.invoked).toEqual([{ name: 'get-log-details', data: null }]);
    });
});

describe("rendererLogMessageToJson", () => {
    test("leaves out the fields that have no value", () => {
        expect(rendererLogMessageToJson({ level: 'info', message: "hello" })).toEqual({ level: 'info', message: "hello" });
    });

    test("keeps the error text of an exception", () => {
        expect(rendererLogMessageToJson({ level: 'exception', message: "failed", error: "stack" })).toEqual({ level: 'exception', message: "failed", error: "stack" });
    });

    test("keeps the tool output, leaving out the stream that has none", () => {
        expect(rendererLogMessageToJson({ level: 'tool', message: "ffmpeg", toolData: { stderr: "warning" } })).toEqual({ level: 'tool', message: "ffmpeg", toolData: { stderr: "warning" } });
    });
});

describe("errorLogText", () => {

    test("keeps a stack that already starts with the message", () => {
        const error = new Error("boom");
        error.stack = "Error: boom\n    at here";

        expect(errorLogText(error)).toBe("Error: boom\n    at here");
    });

    test("leads a stack that is only frames with the name and message", () => {
        const error = new Error("A secret named 'x' already exists");
        error.stack = "handleSave@ziggy-app://app/index.js:1:2";

        expect(errorLogText(error)).toBe("Error: A secret named 'x' already exists\nhandleSave@ziggy-app://app/index.js:1:2");
    });

    test("falls back to the message when there is no stack", () => {
        const error = new Error("no stack");
        error.stack = undefined;

        expect(errorLogText(error)).toBe("no stack");
    });
});
