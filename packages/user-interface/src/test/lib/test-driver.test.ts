/**
 * @jest-environment jsdom
 */

import {
    doClick,
    doLongPressClick,
    doType,
    doDrop,
    getValue,
    doNavigate,
    doMenu,
    doOpenDatabase,
    doSeedDatabases,
    doSeedSecrets,
    doSeedRecent,
    doSeedNews,
    doResetConfig,
    installTestDriver,
    TEST_MENU_EVENT,
    TEST_OPEN_DATABASE_EVENT,
    TEST_SEED_DATABASES_EVENT,
    TEST_SEED_SECRETS_EVENT,
    TEST_SEED_RECENT_EVENT,
    TEST_SEED_NEWS_EVENT,
    TEST_RESET_CONFIG_EVENT,
} from "../../lib/test-driver";
import type { ITestTransport, ITestCommandPayload } from "../../lib/test-driver";

describe("doClick", () => {

    test("clicks the element with the matching data-id", () => {
        document.body.innerHTML = `<button data-id="go">go</button>`;
        const button = document.querySelector(`[data-id="go"]`) as HTMLButtonElement;
        let clicked = 0;
        button.addEventListener("click", () => { clicked += 1; });
        doClick("go");
        expect(clicked).toBe(1);
    });

    test("clicks the nth element when several share a data-id", () => {
        document.body.innerHTML = `
            <button data-id="row">0</button>
            <button data-id="row">1</button>
            <button data-id="row">2</button>`;
        const buttons = document.querySelectorAll(`[data-id="row"]`);
        let clickedIndex = -1;
        buttons.forEach((button, index) => {
            button.addEventListener("click", () => { clickedIndex = index; });
        });
        doClick("row", 2);
        expect(clickedIndex).toBe(2);
    });

    test("does nothing when the element is missing", () => {
        document.body.innerHTML = ``;
        expect(() => doClick("missing")).not.toThrow();
    });
});

describe("doLongPressClick", () => {

    test("dispatches mousedown then mouseup on the target", () => {
        document.body.innerHTML = `<div data-id="tile">tile</div>`;
        const tile = document.querySelector(`[data-id="tile"]`) as HTMLElement;
        const events: string[] = [];
        tile.addEventListener("mousedown", () => events.push("mousedown"));
        tile.addEventListener("mouseup", () => events.push("mouseup"));
        doLongPressClick("tile");
        expect(events).toEqual(["mousedown", "mouseup"]);
    });
});

describe("doType", () => {

    test("sets the nested input value and dispatches input and change", () => {
        document.body.innerHTML = `<div data-id="name"><input type="text" /></div>`;
        const input = document.querySelector(`[data-id="name"] input`) as HTMLInputElement;
        const events: string[] = [];
        input.addEventListener("input", () => events.push("input"));
        input.addEventListener("change", () => events.push("change"));
        doType("name", "Photosphere");
        expect(input.value).toBe("Photosphere");
        expect(events).toEqual(["input", "change"]);
    });
});

describe("doDrop", () => {

    test("dispatches a drop event carrying the file paths onto the target", () => {
        // jsdom does not implement DataTransfer/DragEvent; provide minimal shims.
        const originalDataTransfer = (globalThis as any).DataTransfer;
        const originalDragEvent = (globalThis as any).DragEvent;
        const addedFiles: File[] = [];
        (globalThis as any).DataTransfer = class {
            items = { add: (file: File) => { addedFiles.push(file); } };
        };
        (globalThis as any).DragEvent = class extends Event {
            dataTransfer: unknown;
            constructor(type: string, init: { dataTransfer?: unknown }) {
                super(type, { bubbles: true, cancelable: true });
                this.dataTransfer = init.dataTransfer;
            }
        };
        try {
            document.body.innerHTML = `<div data-id="dropzone">drop here</div>`;
            const dropzone = document.querySelector(`[data-id="dropzone"]`) as HTMLElement;
            let dropped = 0;
            dropzone.addEventListener("drop", () => { dropped += 1; });
            doDrop("dropzone", ["/photos/a.jpg", "/photos/b.jpg"]);
            expect(dropped).toBe(1);
            expect(addedFiles).toHaveLength(2);
            expect((addedFiles[0] as any).__testPath).toBe("/photos/a.jpg");
        }
        finally {
            (globalThis as any).DataTransfer = originalDataTransfer;
            (globalThis as any).DragEvent = originalDragEvent;
        }
    });
});

describe("getValue", () => {

    test("returns the input value when present", () => {
        document.body.innerHTML = `<input data-id="field" value="abc" />`;
        expect(getValue("field")).toBe("abc");
    });

    test("falls back to text content for non-inputs", () => {
        document.body.innerHTML = `<span data-id="label">the label</span>`;
        expect(getValue("label")).toBe("the label");
    });

    test("returns an empty string when the element is missing", () => {
        document.body.innerHTML = ``;
        expect(getValue("nope")).toBe("");
    });
});

describe("doNavigate", () => {

    test("sets the location hash, normalising a leading slash", () => {
        doNavigate("settings");
        expect(window.location.hash).toBe("#/settings");
    });

    test("keeps an existing leading slash", () => {
        doNavigate("/cloud");
        expect(window.location.hash).toBe("#/cloud");
    });
});

describe("installTestDriver", () => {

    //
    // Captures the handler registered by installTestDriver so tests can invoke commands.
    //
    function makeTransport(): { transport: ITestTransport; invoke: (command: string, payload: ITestCommandPayload) => Promise<string | undefined> } {
        let handler: ((command: string, payload: ITestCommandPayload) => Promise<string | undefined>) | undefined;
        const transport: ITestTransport = {
            onCommand(registered) { handler = registered; },
            sendLog() { /* not used here */ },
        };
        return {
            transport,
            invoke: (command, payload) => handler!(command, payload),
        };
    }

    test("routes a click command to the DOM", async () => {
        document.body.innerHTML = `<button data-id="go">go</button>`;
        const button = document.querySelector(`[data-id="go"]`) as HTMLButtonElement;
        let clicked = 0;
        button.addEventListener("click", () => { clicked += 1; });
        const { transport, invoke } = makeTransport();
        installTestDriver(transport);
        await invoke("click", { dataId: "go" });
        expect(clicked).toBe(1);
    });

    test("routes a get-value command and returns the value", async () => {
        document.body.innerHTML = `<input data-id="field" value="xyz" />`;
        const { transport, invoke } = makeTransport();
        installTestDriver(transport);
        const value = await invoke("get-value", { dataId: "field" });
        expect(value).toBe("xyz");
    });

    test("rejects an unknown command", async () => {
        const { transport, invoke } = makeTransport();
        installTestDriver(transport);
        await expect(invoke("create-database", {})).rejects.toThrow("not implemented");
    });

    test("routes a menu command to a window event", async () => {
        const { transport, invoke } = makeTransport();
        installTestDriver(transport);
        let received: string | undefined;
        const listener = (event: Event) => { received = (event as CustomEvent<string>).detail; };
        window.addEventListener(TEST_MENU_EVENT, listener);
        try {
            await invoke("menu", { itemId: "new-database" });
        }
        finally {
            window.removeEventListener(TEST_MENU_EVENT, listener);
        }
        expect(received).toBe("new-database");
    });

    test("routes an open-database command to a window event", async () => {
        const { transport, invoke } = makeTransport();
        installTestDriver(transport);
        let received: string | undefined;
        const listener = (event: Event) => { received = (event as CustomEvent<string>).detail; };
        window.addEventListener(TEST_OPEN_DATABASE_EVENT, listener);
        try {
            await invoke("open-database", { path: "/data/test-db" });
        }
        finally {
            window.removeEventListener(TEST_OPEN_DATABASE_EVENT, listener);
        }
        expect(received).toBe("/data/test-db");
    });
});

describe("doMenu and doOpenDatabase", () => {

    test("doMenu dispatches the menu window event", () => {
        let received: string | undefined;
        const listener = (event: Event) => { received = (event as CustomEvent<string>).detail; };
        window.addEventListener(TEST_MENU_EVENT, listener);
        try {
            doMenu("open-database");
        }
        finally {
            window.removeEventListener(TEST_MENU_EVENT, listener);
        }
        expect(received).toBe("open-database");
    });

    test("doOpenDatabase dispatches the open-database window event", () => {
        let received: string | undefined;
        const listener = (event: Event) => { received = (event as CustomEvent<string>).detail; };
        window.addEventListener(TEST_OPEN_DATABASE_EVENT, listener);
        try {
            doOpenDatabase("/data/fixture-db");
        }
        finally {
            window.removeEventListener(TEST_OPEN_DATABASE_EVENT, listener);
        }
        expect(received).toBe("/data/fixture-db");
    });
});

describe("mobile config-seeding driver commands", () => {

    //
    // Captures the detail of the first event of the given name dispatched while running an action.
    //
    function captureEvent(eventName: string, action: () => void): unknown {
        let detail: unknown;
        const listener = (event: Event) => { detail = (event as CustomEvent).detail; };
        window.addEventListener(eventName, listener);
        try {
            action();
        }
        finally {
            window.removeEventListener(eventName, listener);
        }
        return detail;
    }

    test("doSeedDatabases dispatches the databases to seed", () => {
        const databases = [{ name: "db", description: "", path: "db" }];
        expect(captureEvent(TEST_SEED_DATABASES_EVENT, () => doSeedDatabases(databases))).toEqual(databases);
    });

    test("doSeedSecrets dispatches the secrets to seed", () => {
        const secrets = [{ entry: { name: "s", type: "api-key" }, value: "v" }];
        expect(captureEvent(TEST_SEED_SECRETS_EVENT, () => doSeedSecrets(secrets))).toEqual(secrets);
    });

    test("doSeedRecent dispatches the recent databases to seed", () => {
        const recent = [{ name: "r", description: "", path: "r" }];
        expect(captureEvent(TEST_SEED_RECENT_EVENT, () => doSeedRecent(recent))).toEqual(recent);
    });

    test("doSeedNews dispatches the news items to seed", () => {
        const news = [{ id: "n1", message: "hello" }];
        expect(captureEvent(TEST_SEED_NEWS_EVENT, () => doSeedNews(news))).toEqual(news);
    });

    test("doResetConfig dispatches the reset-config event", () => {
        let fired = false;
        const listener = () => { fired = true; };
        window.addEventListener(TEST_RESET_CONFIG_EVENT, listener);
        try {
            doResetConfig();
        }
        finally {
            window.removeEventListener(TEST_RESET_CONFIG_EVENT, listener);
        }
        expect(fired).toBe(true);
    });

    test("installTestDriver routes seed/reset commands to their handlers", async () => {
        let handler: ((command: string, payload: ITestCommandPayload) => Promise<string | undefined>) | undefined;
        const transport: ITestTransport = {
            onCommand: (incoming) => { handler = incoming; },
            sendLog: () => { /* unused */ },
        };
        installTestDriver(transport);

        const seeded = captureEvent(TEST_SEED_NEWS_EVENT, () => {
            void handler!("seed-news", { news: [{ id: "n1", message: "hi" }] });
        });
        expect(seeded).toEqual([{ id: "n1", message: "hi" }]);

        let resetFired = false;
        const resetListener = () => { resetFired = true; };
        window.addEventListener(TEST_RESET_CONFIG_EVENT, resetListener);
        try {
            await handler!("reset-config", {});
        }
        finally {
            window.removeEventListener(TEST_RESET_CONFIG_EVENT, resetListener);
        }
        expect(resetFired).toBe(true);
    });
});
