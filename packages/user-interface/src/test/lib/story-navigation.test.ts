import { nextStoryIndex } from "../../lib/story-navigation";

describe("nextStoryIndex", () => {

    test("returns -1 for an empty list", () => {
        expect(nextStoryIndex(-1, 1, 0)).toBe(-1);
        expect(nextStoryIndex(-1, -1, 0)).toBe(-1);
        expect(nextStoryIndex(0, 1, 0)).toBe(-1);
    });

    test("forward with no selection selects the first story", () => {
        expect(nextStoryIndex(-1, 1, 5)).toBe(0);
    });

    test("backward with no selection selects the last story", () => {
        expect(nextStoryIndex(-1, -1, 5)).toBe(4);
    });

    test("forward moves to the next story", () => {
        expect(nextStoryIndex(1, 1, 5)).toBe(2);
    });

    test("backward moves to the previous story", () => {
        expect(nextStoryIndex(2, -1, 5)).toBe(1);
    });

    test("forward wraps from the last story to the first", () => {
        expect(nextStoryIndex(4, 1, 5)).toBe(0);
    });

    test("backward wraps from the first story to the last", () => {
        expect(nextStoryIndex(0, -1, 5)).toBe(4);
    });

    test("single story always navigates to itself", () => {
        expect(nextStoryIndex(0, 1, 1)).toBe(0);
        expect(nextStoryIndex(0, -1, 1)).toBe(0);
    });
});
