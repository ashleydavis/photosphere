import type { IJsonObject } from "ziggy-bridge";

//
// The commands the test control connection forwards to the page, performed on the page's DOM by data-id. The page
// answers each with a result. These exist only so the smoke tests can drive the real app, and the core sends them only in
// a test hooks build.
//

//
// A command from the test control connection.
//
export interface ITestCommand {
    // What to do: ready, click, type, get-value, get-text or exists.
    command: string;

    // The data-id of the element to act on.
    dataId?: string;

    // The text to type, for the type command.
    text?: string;
}

//
// What the page answers a command with.
//
export interface ITestResult {
    // Whether the command did what it was asked.
    ok: boolean;

    // The value or text read, for the get commands.
    value?: string;

    // Why the command failed, when it did.
    error?: string;
}

//
// What a command needs to find and act on elements. The page gives the real document and a test gives a stand-in.
//
export interface IElementFinder {
    // Finds the element with the data-id, or null.
    find(dataId: string): IFoundElement | null;
}

//
// An element a command can act on.
//
export interface IFoundElement {
    // The element's text.
    textContent: string | null;

    // The element's value, when it is a control with one.
    value?: string;

    // Clicks the element.
    click(): void;

    // Gives the element the keyboard focus.
    focus(): void;

    // Dispatches an event on the element.
    dispatchEvent(event: Event): boolean;
}

//
// Performs one test command and returns its result. An unknown command or a missing element is a failure with a reason,
// never a silent success.
//
export function performTestCommand(finder: IElementFinder, command: ITestCommand): ITestResult {
    if (command.command === "ready") {
        return { ok: true };
    }
    if (command.dataId === undefined) {
        return { ok: false, error: `The ${command.command} command needs a dataId.` };
    }
    const element = finder.find(command.dataId);
    if (command.command === "exists") {
        return { ok: element !== null };
    }
    if (element === null) {
        return { ok: false, error: `No element has the data-id ${command.dataId}.` };
    }
    if (command.command === "click") {
        element.click();
        return { ok: true };
    }
    if (command.command === "type") {
        if (command.text === undefined) {
            return { ok: false, error: "The type command needs text." };
        }
        element.value = command.text;
        element.dispatchEvent(new Event("input", { bubbles: true }));
        return { ok: true };
    }
    if (command.command === "get-value") {
        return { ok: true, value: element.value ?? "" };
    }
    if (command.command === "get-text") {
        return { ok: true, value: element.textContent ?? "" };
    }
    return { ok: false, error: `Unknown test command ${command.command}.` };
}

//
// Converts a result to the JSON the page sends back on the test-result channel. A field with no value is left out.
//
export function testResultToJson(result: ITestResult): IJsonObject {
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
// Answers the viewport command: the size in pixels of the area the page is drawn in, as "<width>x<height>". Zooming, docking the
// developer tools and going full screen all change it, which is how a test sees the View menu's items do their work.
//
export function performViewportCommand(width: number, height: number): ITestResult {
    return { ok: true, value: `${width}x${height}` };
}

//
// Answers the insert command: puts focus in the element and inserts the text at its cursor the way typing does, so the browser
// records it for undo, which setting a value does not. The page gives the function that does the insertion.
//
export function performInsertCommand(finder: IElementFinder, command: ITestCommand, insertText: (text: string) => boolean): ITestResult {
    if (command.dataId === undefined || command.text === undefined) {
        return { ok: false, error: "The insert command needs a dataId and text." };
    }
    const element = finder.find(command.dataId);
    if (element === null) {
        return { ok: false, error: `No element has the data-id ${command.dataId}.` };
    }
    element.focus();
    if (!insertText(command.text)) {
        return { ok: false, error: "The browser refused to insert the text." };
    }
    return { ok: true };
}
