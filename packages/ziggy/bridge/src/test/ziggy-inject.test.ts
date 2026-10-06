import fs from "fs";
import path from "path";

//
// A stand-in for the page's window, with the native handle of the platform under test.
//
interface IFakeWindow {
    webkit?: { messageHandlers: { ziggy: { postMessage: (text: string) => void } } };
    chrome?: { webview: { postMessage: (text: string) => void; postMessageWithAdditionalObjects?: (text: string, objects: object[]) => void } };
    ZiggyAndroid?: { postMessage: (text: string) => void };
    ziggy?: {
        invoke: (channel: string, data: object | null) => Promise<object>;
        send: (channel: string, data: object | null) => void;
        onMessage: (channel: string, callback: (data: object) => void) => void;
        removeAllListeners: (channel: string) => void;
        getPathForFile: (file: object) => string | undefined;
    };
    __ziggyReceive?: (message: object) => void;
    addEventListener?: (type: string, listener: (event: IFakeDropEvent) => void, capture: boolean) => void;
    DataTransfer?: new () => IFakeDataTransfer;
    DragEvent?: new (type: string, init: object) => IFakeDropEvent;
    File?: new (parts: unknown[], name: string) => { name: string; size: number };
}

const script = fs.readFileSync(path.join(__dirname, "../../inject/ziggy-inject.js"), "utf8");

function inject(fakeWindow: IFakeWindow): void {
    fakeWindow.addEventListener = fakeWindow.addEventListener ?? (() => undefined);
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

//
// A stand-in for a drop event as the inject script sees one.
//
interface IFakeDropEvent {
    type: string;
    dataTransfer: IFakeDataTransfer | null;
    target: IFakeTarget;
    clientX: number;
    clientY: number;
    prevented: boolean;
    stopped: boolean;
    preventDefault: () => void;
    stopImmediatePropagation: () => void;
}

//
// A stand-in for a drop's data.
//
interface IFakeDataTransfer {
    types: string[];
    files: { name: string; size: number }[];
    items: { add: (file: { name: string; size: number }) => void };
    data: Record<string, string>;
    getData: (type: string) => string;
    setData: (type: string, value: string) => void;
}

//
// A stand-in for the element a drop landed on, which records the events dispatched on it.
//
interface IFakeTarget {
    dispatched: IFakeDropEvent[];
    dispatchEvent: (event: IFakeDropEvent) => void;
}

function fakeTransfer(files: { name: string; size: number }[], data: Record<string, string>, types: string[]): IFakeDataTransfer {
    const transfer: IFakeDataTransfer = {
        types,
        files: [...files],
        data: { ...data },
        items: {
            add: file => {
                transfer.files.push(file);
            },
        },
        getData: type => transfer.data[type] ?? "",
        setData: (type, value) => {
            transfer.data[type] = value;
        },
    };
    return transfer;
}

//
// A window that records the drop listener the script registers and can make the events the script creates.
//
function windowForDrops(posted: string[]): IFakeWindow & { dropListeners: ((event: IFakeDropEvent) => void)[] } {
    const dropListeners: ((event: IFakeDropEvent) => void)[] = [];
    const fakeWindow = windowWithWebkit(posted) as IFakeWindow & { dropListeners: ((event: IFakeDropEvent) => void)[] };
    fakeWindow.dropListeners = dropListeners;
    fakeWindow.addEventListener = (type, listener, capture) => {
        if (type === "drop" && capture) {
            dropListeners.push(listener);
        }
    };
    fakeWindow.File = function (this: { name: string; size: number }, parts: unknown[], name: string) {
        return { name, size: parts.length };
    } as unknown as new (parts: unknown[], name: string) => { name: string; size: number };
    fakeWindow.DataTransfer = function () {
        return fakeTransfer([], {}, []);
    } as unknown as new () => IFakeDataTransfer;
    fakeWindow.DragEvent = function (this: IFakeDropEvent, type: string, init: { dataTransfer: IFakeDataTransfer; clientX: number; clientY: number }) {
        return makeEvent(type, init.dataTransfer, { dispatched: [], dispatchEvent: () => undefined }, init.clientX, init.clientY);
    } as unknown as new (type: string, init: object) => IFakeDropEvent;
    return fakeWindow;
}

function makeEvent(type: string, dataTransfer: IFakeDataTransfer | null, target: IFakeTarget, clientX: number, clientY: number): IFakeDropEvent {
    const event: IFakeDropEvent = {
        type,
        dataTransfer,
        target,
        clientX,
        clientY,
        prevented: false,
        stopped: false,
        preventDefault: () => {
            event.prevented = true;
        },
        stopImmediatePropagation: () => {
            event.stopped = true;
        },
    };
    return event;
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

    test("a drop whose file addresses cannot be read asks the core for the paths and is fired again carrying them", async () => {
        const posted: string[] = [];
        const fakeWindow = windowForDrops(posted);
        inject(fakeWindow);
        const target: IFakeTarget = { dispatched: [], dispatchEvent: event => { target.dispatched.push(event); } };
        const drop = makeEvent("drop", fakeTransfer([], { "text/uri-list": "" }, ["text/uri-list", "text/html"]), target, 5, 6);
        fakeWindow.dropListeners[0](drop);
        expect(drop.prevented).toBe(true);
        expect(drop.stopped).toBe(true);
        expect(JSON.parse(posted[0])).toEqual({ id: 1, channel: "get-dropped-paths", data: null });
        fakeWindow.__ziggyReceive!({ id: 1, ok: true, data: ["/home/me/two words.txt", "/home/me/a folder"] });
        await new Promise(resolve => setTimeout(resolve, 0));
        expect(target.dispatched.length).toBe(1);
        const made = target.dispatched[0].dataTransfer!.files;
        expect(made.map(file => file.name)).toEqual(["two words.txt", "a folder"]);
        expect(made.map(file => fakeWindow.ziggy!.getPathForFile(file))).toEqual(["/home/me/two words.txt", "/home/me/a folder"]);
        expect(target.dispatched[0].clientX).toBe(5);
        // The event the script fired is not caught by the script again.
        fakeWindow.dropListeners[0](target.dispatched[0]);
        expect(target.dispatched[0].prevented).toBe(false);
    });

    test("a drop of Files is fired again with Files that give the real paths", async () => {
        const posted: string[] = [];
        const fakeWindow = windowForDrops(posted);
        inject(fakeWindow);
        const target: IFakeTarget = { dispatched: [], dispatchEvent: event => { target.dispatched.push(event); } };
        const files = [{ name: "a.txt", size: 3 }, { name: "b.txt", size: 4 }];
        fakeWindow.dropListeners[0](makeEvent("drop", fakeTransfer(files, {}, ["Files"]), target, 0, 0));
        fakeWindow.__ziggyReceive!({ id: 1, ok: true, data: ["/home/me/a.txt", "/home/me/b.txt"] });
        await new Promise(resolve => setTimeout(resolve, 0));
        const made = target.dispatched[0].dataTransfer!.files;
        expect(made.map(file => file.name)).toEqual(["a.txt", "b.txt"]);
        expect(made.map(file => fakeWindow.ziggy!.getPathForFile(file))).toEqual(["/home/me/a.txt", "/home/me/b.txt"]);
        expect(fakeWindow.ziggy!.getPathForFile({ name: "a.txt", size: 3 })).toBeUndefined();
    });

    test("WebView2 is handed the Files themselves before the core is asked for the paths", () => {
        const posted: string[] = [];
        const withObjects: { text: string; objects: object[] }[] = [];
        const fakeWindow = windowForDrops(posted);
        fakeWindow.chrome = {
            webview: {
                postMessage: text => posted.push(text),
                postMessageWithAdditionalObjects: (text, objects) => withObjects.push({ text, objects }),
            },
        };
        fakeWindow.webkit = undefined;
        inject(fakeWindow);
        const files = [{ name: "a.txt", size: 3 }];
        const target: IFakeTarget = { dispatched: [], dispatchEvent: () => undefined };
        fakeWindow.dropListeners[0](makeEvent("drop", fakeTransfer(files, {}, ["Files"]), target, 0, 0));
        expect(withObjects).toEqual([{ text: "ziggy-file", objects: files }]);
        expect(JSON.parse(posted[0]).channel).toBe("get-dropped-paths");
    });

    test("a drop of a link or of text is left alone", () => {
        const fakeWindow = windowForDrops([]);
        inject(fakeWindow);
        const target: IFakeTarget = { dispatched: [], dispatchEvent: event => { target.dispatched.push(event); } };
        const link = makeEvent("drop", fakeTransfer([], { "text/uri-list": "https://example.com/a" }, ["text/uri-list"]), target, 0, 0);
        const text = makeEvent("drop", fakeTransfer([], { "text/plain": "hello" }, ["text/plain"]), target, 0, 0);
        fakeWindow.dropListeners[0](link);
        fakeWindow.dropListeners[0](text);
        expect(link.prevented || link.stopped || text.prevented || text.stopped).toBe(false);
        expect(target.dispatched.length).toBe(0);
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

    test("window.ziggy exposes exactly these methods and cannot be replaced", () => {
        const fakeWindow = windowWithWebkit([]);
        inject(fakeWindow);
        expect(Object.keys(fakeWindow.ziggy!).sort()).toEqual(["getPathForFile", "invoke", "onMessage", "removeAllListeners", "send"]);
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
