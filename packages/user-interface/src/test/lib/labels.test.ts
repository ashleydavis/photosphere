import { dedupeLabels } from "../../lib/labels";

describe("dedupeLabels", () => {

    test("returns an empty array unchanged", () => {
        expect(dedupeLabels([])).toEqual([]);
    });

    test("returns a list with no duplicates unchanged", () => {
        expect(dedupeLabels(["holiday", "beach", "summer"])).toEqual(["holiday", "beach", "summer"]);
    });

    test("removes duplicate labels", () => {
        expect(dedupeLabels(["photosphere", "test", "photosphere"])).toEqual(["photosphere", "test"]);
    });

    test("preserves the order of first occurrence", () => {
        expect(dedupeLabels(["a", "b", "a", "c", "b"])).toEqual(["a", "b", "c"]);
    });

    test("does not mutate the input array", () => {
        const input = ["x", "x", "y"];
        dedupeLabels(input);
        expect(input).toEqual(["x", "x", "y"]);
    });
});
