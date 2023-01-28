import { createLayout } from "../../lib/create-layout";

describe("layout", () => {

    test("an empty gallery returns an empty layout", () => {

        const galleryWidth = 600;
        const targetRowHeight = 200;
        const rows = createLayout([], galleryWidth, targetRowHeight);
        expect(rows).toEqual([]);
    });

    test("can layout a gallery with a single item", () => {

        const item = {
            thumb: "https://via.placeholder.com/140x100",
            width: 140,
            height: 100,
        };

        const gallery = [ item ];

        const galleryWidth = 600;
        const targetRowHeight = 200;
        const rows = createLayout(gallery, galleryWidth, targetRowHeight);
        expect(rows.length).toBe(1);

        const row = rows[0];
        expect(row.items.length).toBe(1);
        expect(row.items[0].thumb).toBe(item.thumb);
    });

    test("can layout a gallery with multiple items", () => {

        const items = [
            {
                thumb: "https://via.placeholder.com/100x200",
                width: 100,
                height: 200,
            },
            {
                thumb: "https://via.placeholder.com/100x200",
                width: 100,
                height: 200,
            },
            {
                thumb: "https://via.placeholder.com/100x200",
                width: 100,
                height: 200,
            },
        ];

        const galleryWidth = 600;
        const targetRowHeight = 200;
        const rows = createLayout(items, galleryWidth, targetRowHeight);
        expect(rows.length).toBe(1);

        const row = rows[0];
        expect(row.items.length).toBe(3);
        expect(row.items[0].thumb).toBe(items[0].thumb);
        expect(row.items[1].thumb).toBe(items[1].thumb);
        expect(row.items[2].thumb).toBe(items[2].thumb);
    });

    test("items wrap to the next row on overflow", () => {

        const items = [
            {
                thumb: "https://via.placeholder.com/140x100",
                width: 140,
                height: 200,
            },
            {
                thumb: "https://via.placeholder.com/100x140",
                width: 100,
                height: 200,
            },
            {
                thumb: "https://via.placeholder.com/400x50",
                width: 400,
                height: 200,
            },
        ];

        const galleryWidth = 600;
        const targetRowHeight = 200;
        const rows = createLayout(items, galleryWidth, targetRowHeight);
        expect(rows.length).toBe(2);

        const firstRow = rows[0];
        expect(firstRow.items.length).toBe(2);
        expect(firstRow.items[0].thumb).toBe(items[0].thumb);
        expect(firstRow.items[1].thumb).toBe(items[1].thumb);

        const secondRow = rows[1];
        expect(secondRow.items.length).toBe(1);
        expect(secondRow.items[0].thumb).toBe(items[2].thumb);
    });    

    test("items not in the last row are stretched toward the right hand boundary of the gallery", () => {

        const items = [
            {
                thumb: "https://via.placeholder.com/240x200",
                width: 240,
                height: 200,
            },
            {
                thumb: "https://via.placeholder.com/220x200",
                width: 220,
                height: 200,
            },
            {
                thumb: "https://via.placeholder.com/230x200",
                width: 230,
                height: 200,
            },
        ];

        const galleryWidth = 600;
        const targetRowHeight = 200;
        const rows = createLayout(items, galleryWidth, targetRowHeight);
        const firstRow = rows[0];
        expect(firstRow.items.length).toBe(2);
        expect(firstRow.height).toBeGreaterThan(targetRowHeight);

        const item1 = firstRow.items[0];
        expect(item1.width).toBeGreaterThan(items[0].width);
        expect(item1.height).toBeGreaterThan(items[0].height);

        const item2 = firstRow.items[1];
        expect(item2.width).toBeGreaterThan(items[1].width);
        expect(item2.height).toBeGreaterThan(items[1].height);

        const secondRow = rows[1];
        expect(secondRow.items.length).toBe(1);
        expect(secondRow.height).toBeCloseTo(targetRowHeight);

        const item3 = secondRow.items[0];
        expect(item3.width).toBeCloseTo(items[2].width);
        expect(item3.height).toBeCloseTo(items[2].height);
        
    });    
});