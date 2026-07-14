import { responsiveModalSx, MOBILE_SHEET_MEDIA_QUERY, type IMobileSheetSx } from "../../lib/modal-styles";
import { MOBILE_BREAKPOINT_PX } from "../../lib/use-is-mobile";

//
// Reads the mobile sheet block out of the responsive sx. It is keyed by the media query, so it is
// pulled out by that key and narrowed to the sheet shape for the assertions below.
//
function sheetOf(minWidth: number, maxWidth: number): IMobileSheetSx {
    return responsiveModalSx(minWidth, maxWidth)[MOBILE_SHEET_MEDIA_QUERY] as IMobileSheetSx;
}

describe("responsiveModalSx", () => {

    test("clamps the minimum width to the viewport", () => {
        const sx = responsiveModalSx(520, 700);
        expect(sx.minWidth).toBe("min(520px, calc(100vw - 32px))");
    });

    test("clamps the maximum width to the viewport", () => {
        const sx = responsiveModalSx(520, 700);
        expect(sx.maxWidth).toBe("min(700px, calc(100vw - 32px))");
    });

    test("caps the height within the viewport accounting for safe-area insets", () => {
        const sx = responsiveModalSx(480, 640);
        expect(sx.maxHeight).toBe("calc(100vh - env(safe-area-inset-top) - env(safe-area-inset-bottom) - 32px)");
    });

    test("scrolls vertically and never horizontally", () => {
        const sx = responsiveModalSx(340, 340);
        expect(sx.overflowY).toBe("auto");
        expect(sx.overflowX).toBe("hidden");
    });
});

describe("the mobile sheet treatment", () => {

    test("applies below the same breakpoint that useIsMobile uses", () => {
        expect(MOBILE_SHEET_MEDIA_QUERY).toBe(`@media (max-width: ${MOBILE_BREAKPOINT_PX - 1}px)`);
    });

    test("is included in the responsive sx", () => {
        const sx = responsiveModalSx(520, 700);
        expect(sx[MOBILE_SHEET_MEDIA_QUERY]).toBeDefined();
    });

    test("anchors the dialog to the bottom edge of the screen", () => {
        const sheet = sheetOf(520, 700);
        expect(sheet.position).toBe("fixed");
        expect(sheet.top).toBe("auto");
        expect(sheet.bottom).toBe("0px");
        expect(sheet.left).toBe("0px");
        expect(sheet.right).toBe("0px");
    });

    test("undoes the centring transform Joy applies to a centred dialog", () => {
        expect(sheetOf(520, 700).transform).toBe("none");
    });

    test("overrides the desktop widths so the sheet spans the screen", () => {
        const sheet = sheetOf(520, 700);
        expect(sheet.width).toBe("100vw");
        expect(sheet.minWidth).toBe("100vw");
        expect(sheet.maxWidth).toBe("100vw");
    });

    test("leaves the screen behind the sheet partly visible and clears the status bar", () => {
        expect(sheetOf(520, 700).maxHeight).toBe("calc(92vh - env(safe-area-inset-top))");
    });

    test("rounds only the top corners, because the bottom edge runs off the screen", () => {
        expect(sheetOf(520, 700).borderRadius).toBe("20px 20px 0px 0px");
    });

    test("clears the system navigation bar with its bottom padding", () => {
        expect(sheetOf(520, 700).paddingBottom).toBe("calc(20px + env(safe-area-inset-bottom))");
    });

    test("draws a grab handle above the title", () => {
        const handle = sheetOf(520, 700)["&::before"];
        expect(handle.content).toBe('""');
        expect(handle.width).toBe("36px");
        expect(handle.height).toBe("4px");
    });

    test("pins the title so it stays visible while the sheet body scrolls", () => {
        const title = sheetOf(520, 700)["& .MuiDialogTitle-root"];
        expect(title.position).toBe("sticky");
        expect(title.top).toBe("0px");
    });

    test("stacks the actions full width, at a tappable height", () => {
        const actions = sheetOf(520, 700)["& .MuiDialogActions-root"];
        expect(actions.flexDirection).toBe("column-reverse");
        expect(actions.width).toBe("100%");
        expect(actions["& > *"].width).toBe("100%");
        expect(actions["& > *"].minHeight).toBe("48px");
    });
});
