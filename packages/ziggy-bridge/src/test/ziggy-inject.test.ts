import fs from "fs";
import path from "path";

//
// A stand-in for the page's window, with the native handle of the platform under test.
//
interface IFakeWindow {
    webkit?: { messageHandlers: { ziggy: { postMessage: (text: string) => void } } };
    chrome?: { webview: { postMessage: (text: string) => void } };
    ZiggyAndroid?: { postMessage: (text: string) => void };
    ziggy?: {
        invoke: (channel: string, data: object | null) => Promise<object>;
        send: (channel: string, data: object | null) => void;
        onMessage: (channel: string, callback: (data: object) => void) => void;
        removeAllListeners: (channel: string) => void;
    };
    __ziggyReceive?: (message: object) => void;
}

const script = fs.readFileSync(path.join(__dirname, "../../inject/ziggy-inject.js"), "utf8");

function inject(fakeWindow: IFakeWindow): void {
    new Function("window", script)(fakeWindow);
}

function windowWithWebkit(posted: string[]): IFakeWindow {
    return {
        webkit: {
            messageHandlers: {
                ziggy: {
                    postMessage: (text: string) => posted.push(text),
                },
            },
        },
    };
}

describe("ziggy-inject", () => {
    test("invoke posts a request with an id and resolves with the reply's data", async () => {
        const posted: string[] = [];
        const fakeWindow = windowWithWebkit(posted);
        inject(fakeWindow);
        const reply = fakeWindow.ziggy!.invoke("ping", { a: 1 });
        expect(JSON.parse(posted[0])).toEqual({ id: 1, channel: "ping", data: { a: 1 } });
        fakeWindow.__ziggyReceive!({ id: 1, ok: true, data: { answer: 42 } });
        expect(await reply).toEqual({ answer: 42 });
    });

    test("invoke rejects with the core's error", async () => {
        const posted: string[] = [];
        const fakeWindow = windowWithWebkit(posted);
        inject(fakeWindow);
        const reply = fakeWindow.ziggy!.invoke("fail", null);
        fakeWindow.__ziggyReceive!({ id: 1, ok: false, error: "ExampleFailure" });
        await expect(reply).rejects.toThrow("ExampleFailure");
    });

    test("replies are matched to requests by id, in any order", async () => {
        const posted: string[] = [];
        const fakeWindow = windowWithWebkit(posted);
        inject(fakeWindow);
        const first = fakeWindow.ziggy!.invoke("a", null);
        const second = fakeWindow.ziggy!.invoke("b", null);
        fakeWindow.__ziggyReceive!({ id: 2, ok: true, data: "second" });
        fakeWindow.__ziggyReceive!({ id: 1, ok: true, data: "first" });
        expect(await first).toBe("first");
        expect(await second).toBe("second");
    });

    test("send posts a message with no id", () => {
        const posted: string[] = [];
        const fakeWindow = windowWithWebkit(posted);
        inject(fakeWindow);
        fakeWindow.ziggy!.send("cancel-tasks", { source: "s" });
        expect(JSON.parse(posted[0])).toEqual({ channel: "cancel-tasks", data: { source: "s" } });
    });

    test("an event calls every callback registered for its channel and no others", () => {
        const fakeWindow = windowWithWebkit([]);
        inject(fakeWindow);
        const received: object[] = [];
        const other: object[] = [];
        fakeWindow.ziggy!.onMessage("task-message", data => received.push(data));
        fakeWindow.ziggy!.onMessage("task-message", data => received.push(data));
        fakeWindow.ziggy!.onMessage("other", data => other.push(data));
        fakeWindow.__ziggyReceive!({ channel: "task-message", data: { taskId: "t" } });
        expect(received).toEqual([{ taskId: "t" }, { taskId: "t" }]);
        expect(other).toEqual([]);
    });

    test("removeAllListeners stops a channel's events reaching its callbacks", () => {
        const fakeWindow = windowWithWebkit([]);
        inject(fakeWindow);
        const received: object[] = [];
        fakeWindow.ziggy!.onMessage("task-message", data => received.push(data));
        fakeWindow.ziggy!.removeAllListeners("task-message");
        fakeWindow.__ziggyReceive!({ channel: "task-message", data: {} });
        expect(received).toEqual([]);
    });

    test("it posts through WebView2's handle when that is what the web view has", () => {
        const posted: string[] = [];
        const fakeWindow: IFakeWindow = { chrome: { webview: { postMessage: text => posted.push(text) } } };
        inject(fakeWindow);
        fakeWindow.ziggy!.send("x", null);
        expect(posted.length).toBe(1);
    });

    test("it posts through the Android interface object when that is what the web view has", () => {
        const posted: string[] = [];
        const fakeWindow: IFakeWindow = { ZiggyAndroid: { postMessage: text => posted.push(text) } };
        inject(fakeWindow);
        fakeWindow.ziggy!.send("x", null);
        expect(posted.length).toBe(1);
    });

    test("it throws, naming the problem, when the web view has no native handle", () => {
        expect(() => inject({})).toThrow("no native message handler");
    });

    test("window.ziggy exposes exactly four methods and cannot be replaced", () => {
        const fakeWindow = windowWithWebkit([]);
        inject(fakeWindow);
        expect(Object.keys(fakeWindow.ziggy!).sort()).toEqual(["invoke", "onMessage", "removeAllListeners", "send"]);
        expect(() => {
            "use strict";
            (fakeWindow as { ziggy: object }).ziggy = {};
        }).toThrow();
    });

    test("injecting twice keeps the first window.ziggy", () => {
        const fakeWindow = windowWithWebkit([]);
        inject(fakeWindow);
        const first = fakeWindow.ziggy;
        inject(fakeWindow);
        expect(fakeWindow.ziggy).toBe(first);
    });
});
