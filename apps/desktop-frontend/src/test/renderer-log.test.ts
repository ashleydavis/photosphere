import { createRendererLog } from '../lib/renderer-log';
import type { IElectronAPI } from '../lib/electron-ipc';

//
// Builds a minimal IElectronAPI that records the log messages sent to the main process.
//
function makeElectronAPI() {
    return {
        invoke: jest.fn(),
        send: jest.fn(),
        onMessage: jest.fn(),
        removeAllListeners: jest.fn(),
        log: jest.fn(),
        getPathForFile: jest.fn(),
    } as unknown as IElectronAPI;
}

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
        const electronAPI = makeElectronAPI();
        const log = createRendererLog(electronAPI, false);

        log.info("hello");

        expect(consoleLog).toHaveBeenCalledWith("hello");
        expect(electronAPI.log).toHaveBeenCalledWith({ level: 'info', message: "hello" });
    });

    // The whole point of the flag: test mode patches the console to forward to the main process, so a
    // console write here would put the message into app.log a second time, and a duplicate line there
    // answers the next wait_for_log before the event it is waiting for has happened.
    test("does not write to the console when the console is already forwarded", () => {
        const electronAPI = makeElectronAPI();
        const log = createRendererLog(electronAPI, true);

        log.info("hello");

        expect(consoleLog).not.toHaveBeenCalled();
        expect(electronAPI.log).toHaveBeenCalledWith({ level: 'info', message: "hello" });
    });

    test("forwards an event without writing it to the console when the console is already forwarded", () => {
        const electronAPI = makeElectronAPI();
        const log = createRendererLog(electronAPI, true);

        log.event("Source cleanup counted");

        expect(consoleLog).not.toHaveBeenCalled();
        expect(electronAPI.log).toHaveBeenCalledWith({ level: 'event', message: "Source cleanup counted" });
    });

    test("keeps errors and warnings off the console when the console is already forwarded", () => {
        const electronAPI = makeElectronAPI();
        const log = createRendererLog(electronAPI, true);

        log.error("went wrong");
        log.warn("careful");

        expect(consoleError).not.toHaveBeenCalled();
        expect(consoleWarn).not.toHaveBeenCalled();
        expect(electronAPI.log).toHaveBeenCalledWith({ level: 'error', message: "went wrong" });
        expect(electronAPI.log).toHaveBeenCalledWith({ level: 'warn', message: "careful" });
    });
});
