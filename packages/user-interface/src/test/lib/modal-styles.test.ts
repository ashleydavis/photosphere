import { desktopDialogSx, mobileSheetDrawerSx, type IMobileSheetContentSx } from "../../lib/modal-styles";

//
// Reads the sheet panel's styles out of the drawer sx. They are keyed by the Joy content slot's
// class, so they are pulled out by that key for the assertions below.
//
function sheetContent(): IMobileSheetContentSx {
    return mobileSheetDrawerSx()["& .MuiDrawer-content"];
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
});

describe("the mobile sheet treatment", () => {

    test("slides quickly enough that the sheet is not something the user waits for", () => {
        const sx = mobileSheetDrawerSx();
        expect(sx["--Drawer-transitionDuration"]).toBe("0.2s");
        expect(sx["--Drawer-transitionFunction"]).toBe("cubic-bezier(0.32, 0.72, 0, 1)");
    });

    test("matches the close button's inset to the sheet's own corner radius", () => {
        expect(mobileSheetDrawerSx()["--Drawer-contentRadius"]).toBe("20px");
    });

    test("hugs its content instead of taking Joy's fixed fraction of the screen", () => {
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
    });
});
