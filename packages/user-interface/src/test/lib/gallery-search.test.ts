import { applySearch, applySearchTerm, valueMatches } from "../../lib/gallery-search";
import { IGalleryItem } from "../../lib/gallery-item";

//
// Minimal gallery item factory for tests.
//
function makeItem(overrides: Partial<IGalleryItem>): IGalleryItem {
    return {
        _id: "test-id",
        origFileName: "photo.jpg",
        contentType: "image/jpeg",
        width: 100,
        height: 100,
        ...overrides,
    } as IGalleryItem;
}

describe("valueMatches", () => {

    test("matches a string field", () => {
        expect(valueMatches("Hello World", "hello")).toBe(true);
    });

    test("does not match when string field does not contain the term", () => {
        expect(valueMatches("Hello World", "foo")).toBe(false);
    });

    test("matches an element in an array field", () => {
        expect(valueMatches(["cat", "dog", "bird"], "dog")).toBe(true);
    });

    test("does not match when no array element contains the term", () => {
        expect(valueMatches(["cat", "dog", "bird"], "fish")).toBe(false);
    });

    test("matching is case-insensitive", () => {
        expect(valueMatches("Sydney, Australia", "australia")).toBe(true);
    });
});

describe("applySearchTerm", () => {

    test("returns items matching the search term in default fields", () => {
        const items = [
            makeItem({ _id: "1", origFileName: "beach.jpg" }),
            makeItem({ _id: "2", origFileName: "mountain.jpg" }),
        ];
        const result = applySearchTerm("beach", items, ["origFileName"]);
        expect(result).toHaveLength(1);
        expect(result[0]._id).toBe("1");
    });

    test("returns empty array when no items match", () => {
        const items = [
            makeItem({ _id: "1", origFileName: "beach.jpg" }),
        ];
        const result = applySearchTerm("mountain", items, ["origFileName"]);
        expect(result).toHaveLength(0);
    });

    test("matches across multiple fields", () => {
        const items = [
            makeItem({ _id: "1", origFileName: "beach.jpg", location: "Sydney" }),
            makeItem({ _id: "2", origFileName: "mountain.jpg", location: "Alps" }),
        ];
        const result = applySearchTerm("sydney", items, ["origFileName", "location"]);
        expect(result).toHaveLength(1);
        expect(result[0]._id).toBe("1");
    });

    test("matching is case-insensitive", () => {
        const items = [
            makeItem({ _id: "1", origFileName: "Beach.jpg" }),
        ];
        const result = applySearchTerm("beach", items, ["origFileName"]);
        expect(result).toHaveLength(1);
    });

    test("matches array fields like labels", () => {
        const items = [
            makeItem({ _id: "1", labels: ["sunset", "ocean"] } as any),
            makeItem({ _id: "2", labels: ["forest", "mountain"] } as any),
        ];
        const result = applySearchTerm("ocean", items, ["labels"]);
        expect(result).toHaveLength(1);
        expect(result[0]._id).toBe("1");
    });
});

describe("applySearch", () => {

    test("returns all items when search text is empty", () => {
        const items = [
            makeItem({ _id: "1" }),
            makeItem({ _id: "2" }),
        ];
        const result = applySearch(items, "");
        expect(result).toHaveLength(2);
    });

    test("returns all items when search text is only whitespace", () => {
        const items = [makeItem({ _id: "1" })];
        const result = applySearch(items, "   ");
        expect(result).toHaveLength(1);
    });

    test("filters items by search term", () => {
        const items = [
            makeItem({ _id: "1", origFileName: "beach.jpg" }),
            makeItem({ _id: "2", origFileName: "mountain.jpg" }),
        ];
        const result = applySearch(items, "beach");
        expect(result).toHaveLength(1);
        expect(result[0]._id).toBe("1");
    });

    test("applies multiple terms (AND logic)", () => {
        const items = [
            makeItem({ _id: "1", origFileName: "beach.jpg", location: "Sydney" }),
            makeItem({ _id: "2", origFileName: "beach.jpg", location: "Hawaii" }),
        ];
        const result = applySearch(items, "beach sydney");
        expect(result).toHaveLength(1);
        expect(result[0]._id).toBe("1");
    });

    test("supports field-specific search with .field=value syntax", () => {
        const items = [
            makeItem({ _id: "1", origFileName: "beach.jpg", location: "Sydney" }),
            makeItem({ _id: "2", origFileName: "sydney-trip.jpg", location: "Hawaii" }),
        ];
        const result = applySearch(items, ".location=sydney");
        expect(result).toHaveLength(1);
        expect(result[0]._id).toBe("1");
    });

    test("ignores malformed field-specific search terms", () => {
        const items = [
            makeItem({ _id: "1", origFileName: "beach.jpg" }),
        ];
        // No '=' so it's malformed — should not crash and should return all items
        const result = applySearch(items, ".location");
        expect(result).toHaveLength(1);
    });

    test("returned array is a clone of the input when empty search", () => {
        const items = [makeItem({ _id: "1" })];
        const result = applySearch(items, "");
        expect(result).not.toBe(items);
    });
});
