import type { KeyboardEvent } from "react";
import { log } from "utils";

//
// A minimal description of a keyboard event, used to decide a dialog's confirm
// intent without depending on the DOM. Keeping the decision pure makes it
// unit-testable in the headless (non-jsdom) test environment.
//
export interface IDialogKeyEvent {
    //
    // The key that was pressed (e.g. "Enter").
    //
    key: string;

    //
    // True when an earlier handler has already called preventDefault on the event.
    //
    defaultPrevented: boolean;

    //
    // The lower-case tag name of the element the event originated from (e.g. "input", "textarea", "button").
    //
    targetTagName: string;
}

//
// Decides whether a key event inside a dialog should trigger the dialog's
// confirm (primary) action. Enter confirms, except when:
//  - the confirm action is disabled,
//  - another handler has already handled the event (defaultPrevented),
//  - focus is in a textarea (Enter inserts a newline there),
//  - focus is on a button (Enter activates that button itself).
//
export function shouldConfirmOnKey(event: IDialogKeyEvent, confirmDisabled: boolean): boolean {
    if (event.key !== "Enter") {
        return false;
    }
    if (event.defaultPrevented) {
        return false;
    }
    if (confirmDisabled) {
        return false;
    }
    const tagName = event.targetTagName.toLowerCase();
    if (tagName === "textarea") {
        return false;
    }
    if (tagName === "button") {
        return false;
    }
    return true;
}

//
// Builds an onKeyDown handler for a dialog's ModalDialog that invokes the
// confirm (primary) action when the user presses Enter. This implements the
// app-wide convention that Enter confirms a dialog. Escape-to-cancel is already
// provided by MUI's Modal, which calls its onClose handler on Escape.
//
// Do not use this for destructive confirmations (delete/remove dialogs).
// Those must only be confirmed by clicking the button, never by pressing Enter,
// so an accidental keypress cannot destroy data.
//
// The confirm callback may be async; any rejection is caught and logged here so
// callers can pass plain async functions without their own catch handlers.
//
export function createDialogKeyHandler(onConfirm: () => void | Promise<void>, confirmDisabled: boolean): (event: KeyboardEvent) => void {
    return (event: KeyboardEvent) => {
        const target = event.target as HTMLElement;
        const decided = shouldConfirmOnKey({
            key: event.key,
            defaultPrevented: event.defaultPrevented,
            targetTagName: target.tagName,
        }, confirmDisabled);
        if (decided) {
            event.preventDefault();
            const result = onConfirm();
            if (result instanceof Promise) {
                result.catch(err => log.exception('Dialog confirm error:', err as Error));
            }
        }
    };
}
