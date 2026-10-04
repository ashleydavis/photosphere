import { aboutText, buttonForMenuAction } from "../lib/menu-actions";

describe("buttonForMenuAction", () => {
    test("each task action presses the button of the same task", () => {
        expect(buttonForMenuAction("start-short")).toBe("start-short");
        expect(buttonForMenuAction("start-long")).toBe("start-long");
        expect(buttonForMenuAction("start-many")).toBe("start-many");
    });

    test("cancel presses the cancel button", () => {
        expect(buttonForMenuAction("cancel-long")).toBe("cancel-source");
    });

    test("an action with no button, and an unknown one, press nothing", () => {
        expect(buttonForMenuAction("about")).toBeNull();
        expect(buttonForMenuAction("nonsense")).toBeNull();
    });

    test("the about text names the app", () => {
        expect(aboutText).toContain("Ziggy example");
    });
});
