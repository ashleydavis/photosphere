import { computePartialLayout } from "../../lib/create-layout";

describe("layout", () => {

    test("an empty gallery returns an empty layout", () => {

        const galleryWidth = 600;
        const targetRowHeight = 200;
        const rows = computePartialLayout(undefined, [], galleryWidth, targetRowHeight);
        expect(rows).toEqual([]);
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
        const layout = computePartialLayout(undefined, gallery, galleryWidth, targetRowHeight);
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
        const layout = computePartialLayout(undefined, items, galleryWidth, targetRowHeight);
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
        const layout = computePartialLayout(undefined, items, galleryWidth, targetRowHeight);
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
        const layout = computePartialLayout(undefined, items, galleryWidth, targetRowHeight);
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
        expect(secondRow.height).toBeCloseTo(targetRowHeight);

        const item3 = secondRow.items[0];
        expect(item3.thumbWidth).toBeCloseTo(items[2].width);
        expect(item3.thumbHeight).toBeCloseTo(items[2].height);
        
    });

    test("items with a different group wrap to the next row", () => {

        const items: any[] = [
            {
                _id: 1,
                width: 100,
                height: 200,
                group: "a",
            },
            {
                _id: 2,
                width: 100,
                height: 200,
                group: "b",
            },
            {
                _id: 3,
                width: 100,
                height: 200,
                group: "b",
            },
        ];

        const galleryWidth = 600;
        const targetRowHeight = 200;
        const layout = computePartialLayout(undefined, items, galleryWidth, targetRowHeight);
        
        expect(layout.rows.length).toBe(2);
        expect(layout.rows[0].items.length).toBe(1);
        expect(layout.rows[0].items[0]._id).toBe(1);
        expect(layout.rows[1].items.length).toBe(2);
        expect(layout.rows[1].items[0]._id).toBe(2);
        expect(layout.rows[1].items[1]._id).toBe(3);
    });

});