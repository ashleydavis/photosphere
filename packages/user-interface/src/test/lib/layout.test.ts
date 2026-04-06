import { computePartialLayout, deleteFromLayout } from "../../lib/create-layout";

describe("layout", () => {

    test("an empty gallery returns an empty layout", () => {

        const galleryWidth = 600;
        const targetRowHeight = 200;
        const rows = computePartialLayout(undefined, [], galleryWidth, targetRowHeight, () => [], () => "");
        expect(rows).toEqual({
            galleryHeight: 0,
            rows: []
        });
    });

    test("can layout a gallery with a single item", () => {

        const item = {
            _id: 1,
            width: 140,
            height: 100,
        };

        const gallery: any[] = [ item ];

        const galleryWidth = 600;
        const targetRowHeight = 200;
        const layout = computePartialLayout(undefined, gallery, galleryWidth, targetRowHeight, () => [], () => "");

        expect(layout.rows.length).toBe(1);

        const row = layout.rows[0];
        expect(row.items.length).toBe(1);
        expect(row.items[0]._id).toBe(1);
    });

    test("can layout a gallery with multiple items", () => {

        const items: any[] = [
            {
                _id: 1,
                width: 100,
                height: 200,
            },
            {
                _id: 2,
                width: 100,
                height: 200,
            },
            {
                _id: 3,
                width: 100,
                height: 200,
            },
        ];

        const galleryWidth = 600;
        const targetRowHeight = 200;
        const layout = computePartialLayout(undefined, items, galleryWidth, targetRowHeight, () => [], () => "");
        expect(layout.rows.length).toBe(1);

        const row = layout.rows[0];
        expect(row.items.length).toBe(3);
        expect(row.items[0]._id).toBe(1);
        expect(row.items[1]._id).toBe(2);
        expect(row.items[2]._id).toBe(3);
    });

    test("items wrap to the next row on overflow", () => {

        const items: any[] = [
            {
                _id: 1,
                width: 140,
                height: 200,
            },
            {
                _id: 2,
                width: 100,
                height: 200,
            },
            {
                _id: 3,
                width: 400,
                height: 200,
            },
        ];

        const galleryWidth = 600;
        const targetRowHeight = 200;
        const layout = computePartialLayout(undefined, items, galleryWidth, targetRowHeight, () => [], () => "");
        expect(layout.rows.length).toBe(2);

        const firstRow = layout.rows[0];
        expect(firstRow.items.length).toBe(2);
        expect(firstRow.items[0]._id).toBe(1);
        expect(firstRow.items[1]._id).toBe(2);

        const secondRow = layout.rows[1];
        expect(secondRow.items.length).toBe(1);
        expect(secondRow.items[0]._id).toBe(3);
    });

    test("items not in the last row are stretched toward the right hand boundary of the gallery", () => {

        const items: any[] = [
            {
                width: 240,
                height: 200,
            },
            {
                width: 220,
                height: 200,
            },
            {
                width: 230,
                height: 200,
            },
        ];

        const galleryWidth = 600;
        const targetRowHeight = 200;
        const layout = computePartialLayout(undefined, items, galleryWidth, targetRowHeight, () => [], () => "");

        expect(layout.rows.length).toBe(2);

        const firstRow = layout.rows[0];
        expect(firstRow.items.length).toBe(2);
        expect(firstRow.height).toBeGreaterThan(targetRowHeight);

        const item1 = firstRow.items[0];
        expect(item1.thumbWidth).toBeGreaterThan(items[0].width);
        expect(item1.thumbHeight).toBeGreaterThan(items[0].height);

        const item2 = firstRow.items[1];
        expect(item2.thumbWidth).toBeGreaterThan(items[1].width);
        expect(item2.thumbHeight).toBeGreaterThan(items[1].height);

        const secondRow = layout.rows[1];
        expect(secondRow.items.length).toBe(1);
        expect(secondRow.height).toBeGreaterThanOrEqual(targetRowHeight);
        expect(secondRow.height).toBeLessThanOrEqual(targetRowHeight + 5);

        const item3 = secondRow.items[0];
        expect(item3.thumbWidth).toBeCloseTo(items[2].width);
        expect(item3.thumbHeight).toBeCloseTo(items[2].height);
    });
});

describe("deleteFromLayout", () => {

    const galleryWidth = 600;
    const targetRowHeight = 200;
    const noGroup = () => [];
    const noHeading = () => "";

    //
    // Builds a layout from items using computePartialLayout.
    //
    function buildLayout(items: any[]) {
        return computePartialLayout(undefined, items, galleryWidth, targetRowHeight, noGroup, noHeading);
    }

    test("returns the same layout when none of the deleted IDs are present", () => {

        const items: any[] = [
            { _id: "a", width: 100, height: 200 },
            { _id: "b", width: 100, height: 200 },
        ];
        const layout = buildLayout(items);
        const result = deleteFromLayout(layout, ["z"], galleryWidth, targetRowHeight, noGroup, noHeading);

        expect(result).toBe(layout);
    });

    test("returns empty layout when the only item is deleted", () => {

        const items: any[] = [
            { _id: "a", width: 100, height: 200 },
        ];
        const layout = buildLayout(items);
        const result = deleteFromLayout(layout, ["a"], galleryWidth, targetRowHeight, noGroup, noHeading);

        expect(result.rows.length).toBe(0);
        expect(result.galleryHeight).toBe(0);
    });

    test("removes a deleted item and keeps remaining items in the layout", () => {

        const items: any[] = [
            { _id: "a", width: 100, height: 200 },
            { _id: "b", width: 100, height: 200 },
            { _id: "c", width: 100, height: 200 },
        ];
        const layout = buildLayout(items);
        const result = deleteFromLayout(layout, ["b"], galleryWidth, targetRowHeight, noGroup, noHeading);

        const allResultItems = result.rows.flatMap(row => row.items);
        const resultIds = allResultItems.map(item => item._id);

        expect(resultIds).not.toContain("b");
        expect(resultIds).toContain("a");
        expect(resultIds).toContain("c");
    });

    test("reflows items from later rows when an item is deleted from an earlier row", () => {

        // Three items where the first two fill row 1 and the third wraps to row 2.
        const items: any[] = [
            { _id: "a", width: 400, height: 200 },
            { _id: "b", width: 400, height: 200 },
            { _id: "c", width: 400, height: 200 },
        ];
        const layout = buildLayout(items);
        expect(layout.rows.length).toBeGreaterThan(1);

        // Delete one item from the first row — "c" should reflow up.
        const result = deleteFromLayout(layout, ["a"], galleryWidth, targetRowHeight, noGroup, noHeading);

        const allResultItems = result.rows.flatMap(row => row.items);
        expect(allResultItems.map(item => item._id)).toEqual(["b", "c"]);
    });

    test("re-adds heading row correctly when a deletion falls within a grouped section", () => {

        const groupA = () => ["A"];
        const groupB = (item: any) => item._id.startsWith("b") ? ["B"] : ["A"];
        const heading = (group: string[]) => group[0];

        const items: any[] = [
            { _id: "a1", width: 100, height: 200 },
            { _id: "a2", width: 100, height: 200 },
            { _id: "b1", width: 100, height: 200 },
            { _id: "b2", width: 100, height: 200 },
        ];

        const layout = computePartialLayout(undefined, items, galleryWidth, targetRowHeight, groupB, heading);

        // Confirm headings were inserted.
        const headingRows = layout.rows.filter(row => row.type === "heading");
        expect(headingRows.length).toBeGreaterThan(0);

        // Delete an item from group B.
        const result = deleteFromLayout(layout, ["b1"], galleryWidth, targetRowHeight, groupB, heading);

        const resultHeadings = result.rows.filter(row => row.type === "heading");
        const resultItemIds = result.rows.flatMap(row => row.items).map(item => item._id);

        // b2 should still be present under a heading.
        expect(resultItemIds).toContain("b2");
        expect(resultHeadings.length).toBeGreaterThan(0);
        expect(resultItemIds).not.toContain("b1");
    });
});