import { cssTimeToMs, desktopDialogActionsSx, desktopDialogSx, mobileSheetDrawerSx, SHEET_TRANSITION_EASING, type IMobileSheetContentSx } from "../../lib/modal-styles";

//
// Reads the sheet panel's styles out of the drawer sx. They are keyed by the Material Drawer paper
// slot's class, so they are pulled out by that key for the assertions below.
//
function sheetContent(): IMobileSheetContentSx {
    return mobileSheetDrawerSx()["& .MuiDrawer-paper"];
}

describe("desktopDialogSx", () => {

    test("clamps the minimum width to the viewport", () => {
        const sx = desktopDialogSx(520, 700);
        expect(sx.minWidth).toBe("min(520px, calc(100vw - 2 * var(--space-4)))");
    });

    test("clamps the maximum width to the viewport", () => {
        const sx = desktopDialogSx(520, 700);
        expect(sx.maxWidth).toBe("min(700px, calc(100vw - 2 * var(--space-4)))");
    });

    test("caps the height within the viewport accounting for safe-area insets", () => {
        const sx = desktopDialogSx(480, 640);
        expect(sx.maxHeight).toBe("calc(100vh - env(safe-area-inset-top) - env(safe-area-inset-bottom) - 2 * var(--space-4))");
    });

    test("scrolls vertically and never horizontally", () => {
        const sx = desktopDialogSx(340, 340);
        expect(sx.overflowY).toBe("auto");
        expect(sx.overflowX).toBe("hidden");
    });

    test("keeps the same gap to the viewport edges that the size limits allow for", () => {
        expect(desktopDialogSx(340, 340).margin).toBe("var(--space-4)");
    });

    test("puts the close button at the right end of the title row, clear of the title", () => {
        const sx = desktopDialogSx(340, 340);
        const closeButton = sx["& > .MuiIconButton-root"];
        expect(closeButton.position).toBe("absolute");
        expect(closeButton.top).toBe("var(--space-3)");
        expect(closeButton.right).toBe("var(--space-3)");
        expect(sx["& > .MuiIconButton-root ~ .MuiDialogTitle-root"].paddingRight).toBe("calc(var(--space-3) + var(--button-height-md))");
    });

    test("spreads the actions to the two ends of the row, Cancel at the left", () => {
        const actions = desktopDialogSx(340, 340)["& .MuiDialogActions-root"];
        expect(actions.flexDirection).toBe("row");
        expect(actions.justifyContent).toBe("var(--dialog-actions-justify)");
        expect(actions.gap).toBe("var(--space-2)");
        expect(actions["& > :not(style) ~ :not(style)"].marginLeft).toBe("0px");
        expect(actions["& > :first-of-type:not(:last-of-type)"].marginRight).toBe("auto");
    });

    test("puts a lone action at the right end, where the main action sits", () => {
        const actions = desktopDialogSx(340, 340)["& .MuiDialogActions-root"];
        expect(actions["& > :first-of-type:last-of-type"].marginLeft).toBe("auto");
    });

    test("gives a dialog built on Material's Dialog directly the same action row", () => {
        expect(desktopDialogActionsSx()).toEqual(desktopDialogSx(340, 340)["& .MuiDialogActions-root"]);
    });
});

describe("cssTimeToMs", () => {

    test("reads milliseconds", () => {
        expect(cssTimeToMs("250ms")).toBe(250);
    });

    test("converts seconds to milliseconds", () => {
        expect(cssTimeToMs(" 0.25s")).toBe(250);
    });

    test("returns undefined for a value that is not a CSS time, such as a missing token", () => {
        expect(cssTimeToMs("")).toBeUndefined();
        expect(cssTimeToMs("fast")).toBeUndefined();
    });
});

describe("the mobile sheet treatment", () => {

    test("slides with the style guide's standard easing", () => {
        expect(SHEET_TRANSITION_EASING).toBe("var(--ease-standard)");
    });

    test("puts the close button at the right end of the title row, below the grab handle", () => {
        const closeButton = sheetContent()["& > .MuiIconButton-root"];
        expect(closeButton.position).toBe("absolute");
        expect(closeButton.top).toBe("calc(var(--space-2) + var(--space-1) + var(--space-3))");
        expect(closeButton.right).toBe("var(--space-3)");
    });

    test("hugs its content instead of taking a fixed fraction of the screen", () => {
        expect(sheetContent().height).toBe("auto");
    });

    test("leaves the screen behind the sheet partly visible and clears the status bar", () => {
        expect(sheetContent().maxHeight).toBe("calc(var(--dialog-sheet-max-height) - env(safe-area-inset-top))");
    });

    test("rounds only the top corners, as the sheet radius token sets", () => {
        expect(sheetContent().borderRadius).toBe("var(--dialog-sheet-radius)");
        expect(sheetContent().borderRight).toBe("none");
    });

    test("clears the system navigation bar with its bottom padding", () => {
        expect(sheetContent().paddingBottom).toBe("env(safe-area-inset-bottom)");
    });

    test("draws a grab handle in the handle colour that is not squashed by a tall body", () => {
        const handle = sheetContent()["&::before"];
        expect(handle.content).toBe('""');
        expect(handle.width).toBe("calc(var(--space-8) + var(--space-1))");
        expect(handle.height).toBe("var(--space-1)");
        expect(handle.backgroundColor).toBe("var(--dialog-phone-handle-color)");
        expect(handle.flexShrink).toBe(0);
    });

    test("pins the title so it stays visible while the sheet body scrolls", () => {
        const title = sheetContent()["& .MuiDialogTitle-root"];
        expect(title.position).toBe("sticky");
        expect(title.top).toBe("0px");
    });

    test("stacks the actions full width with the main one on top, under a dividing line", () => {
        const actions = sheetContent()["& .MuiDialogActions-root"];
        expect(actions.flexDirection).toBe("column-reverse");
        expect(actions.alignItems).toBe("stretch");
        expect(actions.width).toBe("100%");
        expect(actions.borderTop).toBe("1px solid var(--color-border)");
        expect(actions["& > *"].width).toBe("100%");
        expect(actions["& > *"].minHeight).toBe("var(--button-height-lg)");
        expect(actions["& > *"].marginLeft).toBe("0px");
    });

    test("keeps an icon button in the stack square instead of stretching it across the sheet", () => {
        const iconAction = sheetContent()["& .MuiDialogActions-root"]["& > .MuiIconButton-root"];
        expect(iconAction.width).toBe("auto");
        expect(iconAction.minWidth).toBe("var(--button-height-lg)");
        expect(iconAction.alignSelf).toBe("center");
    });
});
