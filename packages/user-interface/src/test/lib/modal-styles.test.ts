import { responsiveModalSx } from "../../lib/modal-styles";

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
