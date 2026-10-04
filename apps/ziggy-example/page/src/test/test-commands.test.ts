import { IFoundElement, performInsertCommand, performTestCommand, performViewportCommand, testResultToJson } from "../lib/test-commands";

function fakeElement(): IFoundElement & { clicks: number; focused: boolean; events: string[] } {
    const element = {
        textContent: "some text",
        value: "some value",
        clicks: 0,
        focused: false,
        events: [] as string[],
        focus(): void {
            element.focused = true;
        },
        click(): void {
            element.clicks++;
        },
        dispatchEvent(event: Event): boolean {
            element.events.push(event.type);
            return true;
        },
    };
    return element;
}

describe("performTestCommand", () => {
    test("ready always succeeds", () => {
        expect(performTestCommand({ find: () => null }, { command: "ready" })).toEqual({ ok: true });
    });

    test("click clicks the element with the data-id", () => {
        const element = fakeElement();
        const result = performTestCommand({ find: dataId => dataId === "go" ? element : null }, { command: "click", dataId: "go" });
        expect(result).toEqual({ ok: true });
        expect(element.clicks).toBe(1);
    });

    test("type sets the value and dispatches an input event", () => {
        const element = fakeElement();
        const result = performTestCommand({ find: () => element }, { command: "type", dataId: "box", text: "abc" });
        expect(result).toEqual({ ok: true });
        expect(element.value).toBe("abc");
        expect(element.events).toEqual(["input"]);
    });

    test("type without text fails with a reason", () => {
        const result = performTestCommand({ find: () => fakeElement() }, { command: "type", dataId: "box" });
        expect(result.ok).toBe(false);
        expect(result.error).toContain("needs text");
    });

    test("get-value and get-text read the element", () => {
        const finder = { find: () => fakeElement() };
        expect(performTestCommand(finder, { command: "get-value", dataId: "x" })).toEqual({ ok: true, value: "some value" });
        expect(performTestCommand(finder, { command: "get-text", dataId: "x" })).toEqual({ ok: true, value: "some text" });
    });

    test("exists reports whether the element is there", () => {
        expect(performTestCommand({ find: () => fakeElement() }, { command: "exists", dataId: "x" })).toEqual({ ok: true });
        expect(performTestCommand({ find: () => null }, { command: "exists", dataId: "x" })).toEqual({ ok: false });
    });

    test("a missing element is a failure naming the data-id", () => {
        const result = performTestCommand({ find: () => null }, { command: "click", dataId: "ghost" });
        expect(result.ok).toBe(false);
        expect(result.error).toContain("ghost");
    });

    test("a command that needs a data-id and has none fails", () => {
        const result = performTestCommand({ find: () => null }, { command: "click" });
        expect(result.ok).toBe(false);
    });

    test("an unknown command fails with its name", () => {
        const result = performTestCommand({ find: () => fakeElement() }, { command: "dance", dataId: "x" });
        expect(result.ok).toBe(false);
        expect(result.error).toContain("dance");
    });
});

describe("testResultToJson", () => {
    test("leaves out fields with no value", () => {
        expect(testResultToJson({ ok: true })).toEqual({ ok: true });
        expect(testResultToJson({ ok: false, error: "no" })).toEqual({ ok: false, error: "no" });
        expect(testResultToJson({ ok: true, value: "v" })).toEqual({ ok: true, value: "v" });
    });
});

describe("performViewportCommand", () => {
    test("answers the width and height of the page's area", () => {
        expect(performViewportCommand(900, 760)).toEqual({ ok: true, value: "900x760" });
    });
});

describe("performInsertCommand", () => {
    test("focuses the element and inserts the text through the browser", () => {
        const element = fakeElement();
        const inserted: string[] = [];
        const result = performInsertCommand({ find: () => element }, { command: "insert", dataId: "notes", text: "hello" }, text => {
            inserted.push(text);
            return true;
        });
        expect(result).toEqual({ ok: true });
        expect(element.focused).toBe(true);
        expect(inserted).toEqual(["hello"]);
    });

    test("a browser that refuses the insertion is a failure with a reason", () => {
        const result = performInsertCommand({ find: () => fakeElement() }, { command: "insert", dataId: "notes", text: "x" }, () => false);
        expect(result.ok).toBe(false);
        expect(result.error).toContain("refused");
    });

    test("a missing element is a failure naming the data-id", () => {
        const result = performInsertCommand({ find: () => null }, { command: "insert", dataId: "ghost", text: "x" }, () => true);
        expect(result.ok).toBe(false);
        expect(result.error).toContain("ghost");
    });

    test("a command with no text is a failure", () => {
        const result = performInsertCommand({ find: () => fakeElement() }, { command: "insert", dataId: "notes" }, () => true);
        expect(result.ok).toBe(false);
    });
});
