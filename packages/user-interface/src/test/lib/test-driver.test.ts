/**
 * @jest-environment jsdom
 */

import {
    doClick,
    waitForElement,
    isElementVisible,
    doLongPressClick,
    doLongPress,
    doType,
    doDrop,
    doPickFiles,
    TEST_PICK_FILES_EVENT,
    doStageExport,
    doStagePickFolder,
    TEST_STAGE_EXPORT_EVENT,
    TEST_STAGE_PICK_FOLDER_EVENT,
    getValue,
    doNavigate,
    doMenu,
    doOpenDatabase,
    doSeedDatabases,
    doSeedRecent,
    doSeedNews,
    doResetConfig,
    doNotifyDatabaseEdited,
    installTestDriver,
    TEST_MENU_EVENT,
    TEST_OPEN_DATABASE_EVENT,
    TEST_SEED_DATABASES_EVENT,
    TEST_SEED_RECENT_EVENT,
    TEST_SEED_NEWS_EVENT,
    TEST_RESET_CONFIG_EVENT,
    TEST_NOTIFY_DATABASE_EDITED_EVENT,
} from "../../lib/test-driver";
import type { ITestTransport, ITestCommandPayload, ITestResetConfigEventDetail } from "../../lib/test-driver";

//
// Regression guard for the create-database smoke-test failure caused by commit fa673c6b (mobile
// dialogs became Joy Drawers). A closed Joy Drawer stays in the DOM with visibility:hidden, and a
// dialog mounted in several places matches its data-id several times, all but one hidden. The driver
// must act only on the visible one; before this it took the first in DOM order (a hidden drawer), so
// it typed into an invisible form and the visible one stayed empty.
//
describe("hidden elements are not actionable", () => {

    // A hidden wrapper (a closed drawer) followed by a visible one, both carrying the same data-id.
    function twoWrappers(): void {
        document.body.innerHTML = `
            <div id="closed" style="visibility: hidden;">
                <div data-id="field"><input type="text" /></div>
                <button data-id="confirm">Confirm</button>
            </div>
            <div id="open">
                <div data-id="field"><input type="text" /></div>
                <button data-id="confirm">Confirm</button>
            </div>`;
    }

    test("isElementVisible reports a visibility:hidden subtree as not visible", () => {
        document.body.innerHTML = `<div style="visibility: hidden;"><span data-id="x">x</span></div>`;
        expect(isElementVisible(document.querySelector(`[data-id="x"]`)!)).toBe(false);
    });

    test("isElementVisible reports a display:none subtree as not visible", () => {
        document.body.innerHTML = `<div style="display: none;"><span data-id="x">x</span></div>`;
        expect(isElementVisible(document.querySelector(`[data-id="x"]`)!)).toBe(false);
    });

    test("isElementVisible reports a plain element as visible", () => {
        document.body.innerHTML = `<span data-id="x">x</span>`;
        expect(isElementVisible(document.querySelector(`[data-id="x"]`)!)).toBe(true);
    });

    test("doType types into the visible input, not the hidden one that comes first", () => {
        twoWrappers();
        const hiddenInput = document.querySelector(`#closed [data-id="field"] input`) as HTMLInputElement;
        const visibleInput = document.querySelector(`#open [data-id="field"] input`) as HTMLInputElement;
        doType("field", "typed-value");
        expect(visibleInput.value).toBe("typed-value");
        expect(hiddenInput.value).toBe("");
    });

    test("doClick clicks the visible element, not the hidden one that comes first", () => {
        twoWrappers();
        let hiddenClicks = 0;
        let visibleClicks = 0;
        (document.querySelector(`#closed [data-id="confirm"]`) as HTMLElement).addEventListener("click", () => { hiddenClicks += 1; });
        (document.querySelector(`#open [data-id="confirm"]`) as HTMLElement).addEventListener("click", () => { visibleClicks += 1; });
        doClick("confirm");
        expect(visibleClicks).toBe(1);
        expect(hiddenClicks).toBe(0);
    });

    test("waitForElement ignores a hidden match and waits for a visible one", async () => {
        document.body.innerHTML = `<div style="visibility: hidden;"><span data-id="late">x</span></div>`;
        setTimeout(() => {
            document.body.innerHTML += `<span data-id="late">x</span>`;
        }, 80);
        await waitForElement("late", 0, 2000);
        expect(document.querySelectorAll(`[data-id="late"]`).length).toBe(2);
    });
});

//
// Regression guard for the create-database smoke-test failure caused by commit fa673c6b (mobile
// dialogs became Joy Drawers). A closed Joy Drawer stays in the DOM with visibility:hidden, and a
// dialog mounted in several places matches its data-id several times, all but one hidden. The driver
// must act only on the visible one; before this it took the first in DOM order (a hidden drawer), so
// it typed into an invisible form and the visible one stayed empty.
//
describe("hidden elements are not actionable", () => {

    // A hidden wrapper (a closed drawer) followed by a visible one, both carrying the same data-id.
    function twoWrappers(): void {
        document.body.innerHTML = `
            <div id="closed" style="visibility: hidden;">
                <div data-id="field"><input type="text" /></div>
                <button data-id="confirm">Confirm</button>
            </div>
            <div id="open">
                <div data-id="field"><input type="text" /></div>
                <button data-id="confirm">Confirm</button>
            </div>`;
    }

    test("isElementVisible reports a visibility:hidden subtree as not visible", () => {
        document.body.innerHTML = `<div style="visibility: hidden;"><span data-id="x">x</span></div>`;
        expect(isElementVisible(document.querySelector(`[data-id="x"]`)!)).toBe(false);
    });

    test("isElementVisible reports a display:none subtree as not visible", () => {
        document.body.innerHTML = `<div style="display: none;"><span data-id="x">x</span></div>`;
        expect(isElementVisible(document.querySelector(`[data-id="x"]`)!)).toBe(false);
    });

    test("isElementVisible reports a plain element as visible", () => {
        document.body.innerHTML = `<span data-id="x">x</span>`;
        expect(isElementVisible(document.querySelector(`[data-id="x"]`)!)).toBe(true);
    });

    test("doType types into the visible input, not the hidden one that comes first", () => {
        twoWrappers();
        const hiddenInput = document.querySelector(`#closed [data-id="field"] input`) as HTMLInputElement;
        const visibleInput = document.querySelector(`#open [data-id="field"] input`) as HTMLInputElement;
        doType("field", "typed-value");
        expect(visibleInput.value).toBe("typed-value");
        expect(hiddenInput.value).toBe("");
    });

    test("doClick clicks the visible element, not the hidden one that comes first", () => {
        twoWrappers();
        let hiddenClicks = 0;
        let visibleClicks = 0;
        (document.querySelector(`#closed [data-id="confirm"]`) as HTMLElement).addEventListener("click", () => { hiddenClicks += 1; });
        (document.querySelector(`#open [data-id="confirm"]`) as HTMLElement).addEventListener("click", () => { visibleClicks += 1; });
        doClick("confirm");
        expect(visibleClicks).toBe(1);
        expect(hiddenClicks).toBe(0);
    });

    test("waitForElement ignores a hidden match and waits for a visible one", async () => {
        document.body.innerHTML = `<div style="visibility: hidden;"><span data-id="late">x</span></div>`;
        setTimeout(() => {
            document.body.innerHTML += `<span data-id="late">x</span>`;
        }, 80);
        await waitForElement("late", 0, 2000);
        expect(document.querySelectorAll(`[data-id="late"]`).length).toBe(2);
    });
});

//
// Regression guard for the create-database smoke-test failure caused by commit fa673c6b (mobile
// dialogs became Joy Drawers). A closed Joy Drawer stays in the DOM with visibility:hidden, and a
// dialog mounted in several places matches its data-id several times, all but one hidden. The driver
// must act only on the visible one; before this it took the first in DOM order (a hidden drawer), so
// it typed into an invisible form and the visible one stayed empty.
//
describe("hidden elements are not actionable", () => {

    // A hidden wrapper (a closed drawer) followed by a visible one, both carrying the same data-id.
    function twoWrappers(): void {
        document.body.innerHTML = `
            <div id="closed" style="visibility: hidden;">
                <div data-id="field"><input type="text" /></div>
                <button data-id="confirm">Confirm</button>
            </div>
            <div id="open">
                <div data-id="field"><input type="text" /></div>
                <button data-id="confirm">Confirm</button>
            </div>`;
    }

    test("isElementVisible reports a visibility:hidden subtree as not visible", () => {
        document.body.innerHTML = `<div style="visibility: hidden;"><span data-id="x">x</span></div>`;
        expect(isElementVisible(document.querySelector(`[data-id="x"]`)!)).toBe(false);
    });

    test("isElementVisible reports a display:none subtree as not visible", () => {
        document.body.innerHTML = `<div style="display: none;"><span data-id="x">x</span></div>`;
        expect(isElementVisible(document.querySelector(`[data-id="x"]`)!)).toBe(false);
    });

    test("isElementVisible reports a plain element as visible", () => {
        document.body.innerHTML = `<span data-id="x">x</span>`;
        expect(isElementVisible(document.querySelector(`[data-id="x"]`)!)).toBe(true);
    });

    test("doType types into the visible input, not the hidden one that comes first", () => {
        twoWrappers();
        const hiddenInput = document.querySelector(`#closed [data-id="field"] input`) as HTMLInputElement;
        const visibleInput = document.querySelector(`#open [data-id="field"] input`) as HTMLInputElement;
        doType("field", "typed-value");
        expect(visibleInput.value).toBe("typed-value");
        expect(hiddenInput.value).toBe("");
    });

    test("doClick clicks the visible element, not the hidden one that comes first", () => {
        twoWrappers();
        let hiddenClicks = 0;
        let visibleClicks = 0;
        (document.querySelector(`#closed [data-id="confirm"]`) as HTMLElement).addEventListener("click", () => { hiddenClicks += 1; });
        (document.querySelector(`#open [data-id="confirm"]`) as HTMLElement).addEventListener("click", () => { visibleClicks += 1; });
        doClick("confirm");
        expect(visibleClicks).toBe(1);
        expect(hiddenClicks).toBe(0);
    });

    test("waitForElement ignores a hidden match and waits for a visible one", async () => {
        document.body.innerHTML = `<div style="visibility: hidden;"><span data-id="late">x</span></div>`;
        setTimeout(() => {
            document.body.innerHTML += `<span data-id="late">x</span>`;
        }, 80);
        await waitForElement("late", 0, 2000);
        expect(document.querySelectorAll(`[data-id="late"]`).length).toBe(2);
    });
});

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

describe("waitForElement", () => {

    test("resolves when the element is already present", async () => {
        document.body.innerHTML = `<button data-id="go">go</button>`;
        await waitForElement("go", 0, 1000);
        expect(document.querySelector(`[data-id="go"]`)).not.toBeNull();
    });

    test("resolves once an element that renders later appears", async () => {
        document.body.innerHTML = ``;
        setTimeout(() => {
            document.body.innerHTML = `<button data-id="late">late</button>`;
        }, 100);
        await waitForElement("late", 0, 2000);
        expect(document.querySelector(`[data-id="late"]`)).not.toBeNull();
    });

    test("resolves after the timeout when the element never appears", async () => {
        document.body.innerHTML = ``;
        await waitForElement("missing", 0, 100);
        expect(document.querySelector(`[data-id="missing"]`)).toBeNull();
    });

    test("waits for the nth element when several share a data-id", async () => {
        document.body.innerHTML = `<div data-id="row">0</div>`;
        setTimeout(() => {
            document.body.innerHTML = `
                <div data-id="row">0</div>
                <div data-id="row">1</div>`;
        }, 100);
        await waitForElement("row", 1, 2000);
        expect(document.querySelectorAll(`[data-id="row"]`)).toHaveLength(2);
    });
});

//
// The gesture that drives mobile selection mode. Unlike doLongPressClick (immediate release = short
// click), doLongPress holds the button down past the gesture's delay, so a useLongPress-style
// handler's onLongPress fires. This is what test 18 uses to select a gallery item, whose selection
// checkbox is display:none until selecting mode turns on.
//
describe("doLongPress", () => {

    test("holds past the gesture delay so a long-press handler fires (and a short click would not)", async () => {
        document.body.innerHTML = `<div data-id="item">item</div>`;
        const element = document.querySelector(`[data-id="item"]`) as HTMLElement;
        let longPressed = false;
        let clicked = false;
        let timer: NodeJS.Timeout | undefined;
        // Mirror useLongPress: mousedown starts a timer, mouseup fires onClick only if it has not
        // yet elapsed. The gallery leaves the delay effectively immediate; 100ms here is well under
        // doLongPress's 700ms hold so onLongPress fires.
        element.addEventListener("mousedown", () => { timer = setTimeout(() => { longPressed = true; }, 100); });
        element.addEventListener("mouseup", () => {
            if (!longPressed && timer) {
                clearTimeout(timer);
                clicked = true;
            }
        });
        await doLongPress("item");
        expect(longPressed).toBe(true);
        expect(clicked).toBe(false);
    }, 5000);

    test("acts on the visible element, not a hidden duplicate", async () => {
        document.body.innerHTML = `
            <div id="closed" style="visibility: hidden;"><div data-id="item">hidden</div></div>
            <div id="open"><div data-id="item">visible</div></div>`;
        let pressedText = "";
        document.querySelectorAll(`[data-id="item"]`).forEach(el => {
            el.addEventListener("mousedown", () => { pressedText = el.textContent ?? ""; });
        });
        await doLongPress("item");
        expect(pressedText).toBe("visible");
    }, 5000);
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

describe("doPickFiles", () => {

    test("dispatches the pick-files event carrying the staged paths", () => {
        const received: string[][] = [];
        const listener = (event: Event) => {
            received.push((event as CustomEvent<string[]>).detail);
        };
        window.addEventListener(TEST_PICK_FILES_EVENT, listener);
        try {
            doPickFiles([".import-tmp/a.jpg", ".import-tmp/b.png"]);
            expect(received).toEqual([[".import-tmp/a.jpg", ".import-tmp/b.png"]]);
        }
        finally {
            window.removeEventListener(TEST_PICK_FILES_EVENT, listener);
        }
    });
});

describe("doStageExport", () => {

    test("dispatches the stage-export event carrying the outcome", () => {
        const received: string[] = [];
        const listener = (event: Event) => {
            received.push((event as CustomEvent<string>).detail);
        };
        window.addEventListener(TEST_STAGE_EXPORT_EVENT, listener);
        try {
            doStageExport("cancelled");
            expect(received).toEqual(["cancelled"]);
        }
        finally {
            window.removeEventListener(TEST_STAGE_EXPORT_EVENT, listener);
        }
    });
});

describe("doStagePickFolder", () => {

    test("dispatches the stage-pick-folder event carrying the path", () => {
        const received: (string | null)[] = [];
        const listener = (event: Event) => {
            received.push((event as CustomEvent<string | null>).detail);
        };
        window.addEventListener(TEST_STAGE_PICK_FOLDER_EVENT, listener);
        try {
            doStagePickFolder("my-database");
            doStagePickFolder(null);
            expect(received).toEqual(["my-database", null]);
        }
        finally {
            window.removeEventListener(TEST_STAGE_PICK_FOLDER_EVENT, listener);
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

    test("routes a pick-files command to the pick-files window event", async () => {
        const received: string[][] = [];
        const listener = (event: Event) => {
            received.push((event as CustomEvent<string[]>).detail);
        };
        window.addEventListener(TEST_PICK_FILES_EVENT, listener);
        try {
            const { transport, invoke } = makeTransport();
            installTestDriver(transport);
            await invoke("pick-files", { paths: [".import-tmp/x.jpg"] });
            expect(received).toEqual([[".import-tmp/x.jpg"]]);
        }
        finally {
            window.removeEventListener(TEST_PICK_FILES_EVENT, listener);
        }
    });

    test("routes a cycle-advance command to the cycle-advance window event", async () => {
        const { transport, invoke } = makeTransport();
        installTestDriver(transport);
        let received = 0;
        const listener = () => { received += 1; };
        window.addEventListener("cycle-advance", listener);
        try {
            await invoke("cycle-advance", {});
        }
        finally {
            window.removeEventListener("cycle-advance", listener);
        }
        expect(received).toBe(1);
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

    test("doResetConfig awaits the keychain clear a listener registers", async () => {
        let resolveClear: (() => void) | undefined;
        const listener = (event: Event) => {
            const detail = (event as CustomEvent<ITestResetConfigEventDetail>).detail;
            detail.waitFor(new Promise<void>(resolve => { resolveClear = resolve; }));
        };
        window.addEventListener(TEST_RESET_CONFIG_EVENT, listener);
        try {
            let settled = false;
            const pending = doResetConfig().then(() => { settled = true; });
            // Not resolved until the registered clear completes.
            await Promise.resolve();
            expect(settled).toBe(false);
            resolveClear!();
            await pending;
            expect(settled).toBe(true);
        }
        finally {
            window.removeEventListener(TEST_RESET_CONFIG_EVENT, listener);
        }
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
            void doResetConfig();
        }
        finally {
            window.removeEventListener(TEST_RESET_CONFIG_EVENT, listener);
        }
        expect(fired).toBe(true);
    });

    test("doNotifyDatabaseEdited dispatches the database-edited event", () => {
        let fired = false;
        const listener = () => { fired = true; };
        window.addEventListener(TEST_NOTIFY_DATABASE_EDITED_EVENT, listener);
        try {
            doNotifyDatabaseEdited();
        }
        finally {
            window.removeEventListener(TEST_NOTIFY_DATABASE_EDITED_EVENT, listener);
        }
        expect(fired).toBe(true);
    });

    //
    // Regression guard for the 34-sync smoke-test failure: the notify-database-edited command was
    // missing from the driver's command switch (and from the control bridge's routes), so the sync the
    // test asked for never started and navbar-sync-state stayed "idle" forever.
    //
    test("installTestDriver routes the database-edited command to its handler", async () => {
        let handler: ((command: string, payload: ITestCommandPayload) => Promise<string | undefined>) | undefined;
        const transport: ITestTransport = {
            onCommand: (incoming) => { handler = incoming; },
            sendLog: () => { /* unused */ },
        };
        installTestDriver(transport);

        let editedFired = false;
        const editedListener = () => { editedFired = true; };
        window.addEventListener(TEST_NOTIFY_DATABASE_EDITED_EVENT, editedListener);
        try {
            await handler!("notify-database-edited", {});
        }
        finally {
            window.removeEventListener(TEST_NOTIFY_DATABASE_EDITED_EVENT, editedListener);
        }
        expect(editedFired).toBe(true);
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
