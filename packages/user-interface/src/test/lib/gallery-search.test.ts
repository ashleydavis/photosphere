import { applyLabelsTerm, applySearch, applySearchTerm, tokenizeSearchText, valueMatches } from "../../lib/gallery-search";
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

describe("tokenizeSearchText", () => {

    test("splits simple space-separated terms", () => {
        expect(tokenizeSearchText("beach sydney")).toEqual(["beach", "sydney"]);
    });

    test("treats a quoted string with spaces as one token", () => {
        expect(tokenizeSearchText('.labels="one thing"')).toEqual(['.labels="one thing"']);
    });

    test("handles a mix of quoted and unquoted tokens", () => {
        expect(tokenizeSearchText('beach .labels="one thing" sydney')).toEqual([
            "beach",
            '.labels="one thing"',
            "sydney",
        ]);
    });

    test("handles multiple quoted tokens", () => {
        expect(tokenizeSearchText('.labels="one thing"|"another label"')).toEqual([
            '.labels="one thing"|"another label"',
        ]);
    });

    test("trims whitespace from tokens", () => {
        expect(tokenizeSearchText("  beach  sydney  ")).toEqual(["beach", "sydney"]);
    });
});

describe("applyLabelsTerm", () => {

    test('"-" matches item with labels undefined', () => {
        const items = [makeItem({ _id: "1" })];
        expect(applyLabelsTerm("-", items)).toHaveLength(1);
    });

    test('"-" matches item with empty labels array', () => {
        const items = [makeItem({ _id: "1", labels: [] } as any)];
        expect(applyLabelsTerm("-", items)).toHaveLength(1);
    });

    test('"-" does not match item with labels present', () => {
        const items = [makeItem({ _id: "1", labels: ["birthday"] } as any)];
        expect(applyLabelsTerm("-", items)).toHaveLength(0);
    });

    test("single unquoted value matches a label by substring", () => {
        const items = [
            makeItem({ _id: "1", labels: ["my-birthday"] } as any),
            makeItem({ _id: "2", labels: ["vacation"] } as any),
        ];
        const result = applyLabelsTerm("birthday", items);
        expect(result).toHaveLength(1);
        expect(result[0]._id).toBe("1");
    });

    test("single quoted value matches a multi-word label", () => {
        const items = [
            makeItem({ _id: "1", labels: ["one thing"] } as any),
            makeItem({ _id: "2", labels: ["another"] } as any),
        ];
        const result = applyLabelsTerm('"one thing"', items);
        expect(result).toHaveLength(1);
        expect(result[0]._id).toBe("1");
    });

    test("| OR matches item with either label", () => {
        const items = [
            makeItem({ _id: "1", labels: ["birthday"] } as any),
            makeItem({ _id: "2", labels: ["vacation"] } as any),
            makeItem({ _id: "3", labels: ["work"] } as any),
        ];
        const result = applyLabelsTerm("birthday|vacation", items);
        expect(result).toHaveLength(2);
        expect(result.map(item => item._id)).toEqual(["1", "2"]);
    });

    test("| OR does not match item with neither label", () => {
        const items = [makeItem({ _id: "1", labels: ["work"] } as any)];
        expect(applyLabelsTerm("birthday|vacation", items)).toHaveLength(0);
    });

    test("| OR with quoted multi-word alternatives", () => {
        const items = [
            makeItem({ _id: "1", labels: ["one thing"] } as any),
            makeItem({ _id: "2", labels: ["another label"] } as any),
            makeItem({ _id: "3", labels: ["unrelated"] } as any),
        ];
        const result = applyLabelsTerm('"one thing"|"another label"', items);
        expect(result).toHaveLength(2);
    });

    test("& AND matches item that has both labels", () => {
        const items = [
            makeItem({ _id: "1", labels: ["birthday", "family"] } as any),
            makeItem({ _id: "2", labels: ["birthday"] } as any),
            makeItem({ _id: "3", labels: ["family"] } as any),
        ];
        const result = applyLabelsTerm("birthday&family", items);
        expect(result).toHaveLength(1);
        expect(result[0]._id).toBe("1");
    });

    test("& AND with quoted multi-word values", () => {
        const items = [
            makeItem({ _id: "1", labels: ["one thing", "another label"] } as any),
            makeItem({ _id: "2", labels: ["one thing"] } as any),
        ];
        const result = applyLabelsTerm('"one thing"&"another label"', items);
        expect(result).toHaveLength(1);
        expect(result[0]._id).toBe("1");
    });

    test("matching is case-insensitive", () => {
        const items = [makeItem({ _id: "1", labels: ["Birthday"] } as any)];
        expect(applyLabelsTerm("birthday", items)).toHaveLength(1);
    });

    test("does not match item with no labels", () => {
        const items = [makeItem({ _id: "1" })];
        expect(applyLabelsTerm("birthday", items)).toHaveLength(0);
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

    test(".labels=value filters by label", () => {
        const items = [
            makeItem({ _id: "1", labels: ["my-birthday"] } as any),
            makeItem({ _id: "2", labels: ["vacation"] } as any),
        ];
        const result = applySearch(items, ".labels=my-birthday");
        expect(result).toHaveLength(1);
        expect(result[0]._id).toBe("1");
    });

    test('.labels="multi word" matches multi-word label', () => {
        const items = [
            makeItem({ _id: "1", labels: ["one thing"] } as any),
            makeItem({ _id: "2", labels: ["another"] } as any),
        ];
        const result = applySearch(items, '.labels="one thing"');
        expect(result).toHaveLength(1);
        expect(result[0]._id).toBe("1");
    });

    test(".labels=a|b matches items with either label (OR)", () => {
        const items = [
            makeItem({ _id: "1", labels: ["birthday"] } as any),
            makeItem({ _id: "2", labels: ["vacation"] } as any),
            makeItem({ _id: "3", labels: ["work"] } as any),
        ];
        const result = applySearch(items, ".labels=birthday|vacation");
        expect(result).toHaveLength(2);
    });

    test(".labels=a&b matches items with both labels (AND)", () => {
        const items = [
            makeItem({ _id: "1", labels: ["birthday", "family"] } as any),
            makeItem({ _id: "2", labels: ["birthday"] } as any),
        ];
        const result = applySearch(items, ".labels=birthday&family");
        expect(result).toHaveLength(1);
        expect(result[0]._id).toBe("1");
    });

    test('.labels=- matches items with no labels', () => {
        const items = [
            makeItem({ _id: "1" }),
            makeItem({ _id: "2", labels: ["birthday"] } as any),
        ];
        const result = applySearch(items, ".labels=-");
        expect(result).toHaveLength(1);
        expect(result[0]._id).toBe("1");
    });

    test("free-text term after .labels= searches all fields", () => {
        const items = [
            makeItem({ _id: "1", labels: ["birthday"], origFileName: "beach.jpg" }),
            makeItem({ _id: "2", labels: ["birthday"], origFileName: "mountain.jpg" }),
        ];
        const result = applySearch(items, ".labels=birthday beach");
        expect(result).toHaveLength(1);
        expect(result[0]._id).toBe("1");
    });
});
