import { shouldConfirmOnKey, type IDialogKeyEvent } from "../../lib/dialog-keys";

//
// Builds a default key event description for tests, overridden per case.
//
function makeEvent(overrides: Partial<IDialogKeyEvent>): IDialogKeyEvent {
    return {
        key: "Enter",
        defaultPrevented: false,
        targetTagName: "input",
        ...overrides,
    };
}

describe("shouldConfirmOnKey", () => {

    test("confirms when Enter is pressed in a text input", () => {
        expect(shouldConfirmOnKey(makeEvent({ targetTagName: "input" }), false)).toBe(true);
    });

    test("confirms when Enter is pressed and the dialog body itself is focused", () => {
        expect(shouldConfirmOnKey(makeEvent({ targetTagName: "div" }), false)).toBe(true);
    });

    test("does not confirm for keys other than Enter", () => {
        expect(shouldConfirmOnKey(makeEvent({ key: "a" }), false)).toBe(false);
        expect(shouldConfirmOnKey(makeEvent({ key: "Escape" }), false)).toBe(false);
        expect(shouldConfirmOnKey(makeEvent({ key: " " }), false)).toBe(false);
    });

    test("does not confirm when the confirm action is disabled", () => {
        expect(shouldConfirmOnKey(makeEvent({ targetTagName: "input" }), true)).toBe(false);
    });

    test("does not confirm when the event was already handled", () => {
        expect(shouldConfirmOnKey(makeEvent({ defaultPrevented: true }), false)).toBe(false);
    });

    test("does not confirm from within a textarea so Enter inserts a newline", () => {
        expect(shouldConfirmOnKey(makeEvent({ targetTagName: "textarea" }), false)).toBe(false);
    });

    test("does not confirm when a button is focused so the button handles Enter itself", () => {
        expect(shouldConfirmOnKey(makeEvent({ targetTagName: "button" }), false)).toBe(false);
    });

    test("is case-insensitive about the target tag name", () => {
        expect(shouldConfirmOnKey(makeEvent({ targetTagName: "TEXTAREA" }), false)).toBe(false);
        expect(shouldConfirmOnKey(makeEvent({ targetTagName: "BUTTON" }), false)).toBe(false);
        expect(shouldConfirmOnKey(makeEvent({ targetTagName: "INPUT" }), false)).toBe(true);
    });
});
