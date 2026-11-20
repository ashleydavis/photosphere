import { desktopDialogActionsSx, desktopDialogSx, mobileSheetDrawerSx, SHEET_TRANSITION_DURATION_MS, SHEET_TRANSITION_EASING, type IMobileSheetContentSx } from "../../lib/modal-styles";

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
        expect(sx.minWidth).toBe("min(520px, calc(100vw - 32px))");
    });

    test("clamps the maximum width to the viewport", () => {
        const sx = desktopDialogSx(520, 700);
        expect(sx.maxWidth).toBe("min(700px, calc(100vw - 32px))");
    });

    test("caps the height within the viewport accounting for safe-area insets", () => {
        const sx = desktopDialogSx(480, 640);
        expect(sx.maxHeight).toBe("calc(100vh - env(safe-area-inset-top) - env(safe-area-inset-bottom) - 32px)");
    });

    test("scrolls vertically and never horizontally", () => {
        const sx = desktopDialogSx(340, 340);
        expect(sx.overflowY).toBe("auto");
        expect(sx.overflowX).toBe("hidden");
    });

    test("keeps the same gap to the viewport edges that the size limits allow for", () => {
        expect(desktopDialogSx(340, 340).margin).toBe("16px");
    });

    test("puts the close button in the top-right corner", () => {
        const closeButton = desktopDialogSx(340, 340)["& > .MuiIconButton-root"];
        expect(closeButton.position).toBe("absolute");
        expect(closeButton.top).toBe("8px");
        expect(closeButton.right).toBe("8px");
    });

    test("lays the actions out right to left, still right-aligned and spaced by the row's gap", () => {
        const actions = desktopDialogSx(340, 340)["& .MuiDialogActions-root"];
        expect(actions.flexDirection).toBe("row-reverse");
        expect(actions.justifyContent).toBe("flex-start");
        expect(actions.gap).toBe("8px");
        expect(actions["& > :not(style) ~ :not(style)"].marginLeft).toBe("0px");
    });

    test("gives a dialog built on Material's Dialog directly the same action row", () => {
        expect(desktopDialogActionsSx()).toEqual(desktopDialogSx(340, 340)["& .MuiDialogActions-root"]);
    });
});

describe("the mobile sheet treatment", () => {

    test("slides quickly enough that the sheet is not something the user waits for", () => {
        expect(SHEET_TRANSITION_DURATION_MS).toBe(200);
        expect(SHEET_TRANSITION_EASING).toBe("cubic-bezier(0.32, 0.72, 0, 1)");
    });

    test("matches the close button's inset to the sheet's own corner radius", () => {
        const closeButton = sheetContent()["& > .MuiIconButton-root"];
        expect(closeButton.position).toBe("absolute");
        expect(closeButton.top).toBe("calc(20px / 2)");
        expect(closeButton.right).toBe("calc(20px / 2)");
    });

    test("hugs its content instead of taking a fixed fraction of the screen", () => {
        expect(sheetContent().height).toBe("auto");
    });

    test("leaves the screen behind the sheet partly visible and clears the status bar", () => {
        expect(sheetContent().maxHeight).toBe("calc(92vh - env(safe-area-inset-top))");
    });

    test("rounds only the top corners, because the bottom edge runs off the screen", () => {
        expect(sheetContent().borderRadius).toBe("20px 20px 0px 0px");
    });

    test("clears the system navigation bar with its bottom padding", () => {
        expect(sheetContent().paddingBottom).toBe("calc(20px + env(safe-area-inset-bottom))");
    });

    test("draws a grab handle above the title that is not squashed by a tall body", () => {
        const handle = sheetContent()["&::before"];
        expect(handle.content).toBe('""');
        expect(handle.width).toBe("36px");
        expect(handle.height).toBe("4px");
        expect(handle.flexShrink).toBe(0);
    });

    test("pins the title so it stays visible while the sheet body scrolls", () => {
        const title = sheetContent()["& .MuiDialogTitle-root"];
        expect(title.position).toBe("sticky");
        expect(title.top).toBe("0px");
    });

    test("stacks the actions full width, at a tappable height", () => {
        const actions = sheetContent()["& .MuiDialogActions-root"];
        expect(actions.flexDirection).toBe("column-reverse");
        expect(actions.width).toBe("100%");
        expect(actions["& > *"].width).toBe("100%");
        expect(actions["& > *"].minHeight).toBe("48px");
        expect(actions["& > *"].marginLeft).toBe("0px");
    });
});
