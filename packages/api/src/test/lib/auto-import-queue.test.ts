import { AutoImportQueue, createBackfillCursor } from "../../lib/auto-import-queue";
import { IMediaItem } from "../../lib/media-source";

//
// Makes a media item with the given source id. The other fields do not matter to the pacing, which
// is the point: this class decides order and rate, nothing else.
//
function mediaItem(sourceId: string): IMediaItem {
    return {
        sourceId,
        filePath: `/photos/${sourceId}`,
        displayName: sourceId,
        contentType: "image/jpeg",
        size: 1000,
        createdAt: new Date("2026-01-01T00:00:00.000Z"),
    };
}

//
// Makes a list of media items named item-0, item-1 and so on.
//
function mediaItems(count: number): IMediaItem[] {
    const items: IMediaItem[] = [];
    for (let index = 0; index < count; index += 1) {
        items.push(mediaItem(`item-${index}`));
    }
    return items;
}

//
// The source ids released by a batch, which is what every assertion here is about.
//
function idsOf(items: IMediaItem[]): string[] {
    return items.map(item => item.sourceId);
}

describe("AutoImportQueue", () => {

    const startMs = 1000000;

    test("nothing is released from an empty queue", () => {
        const queue = new AutoImportQueue(60, createBackfillCursor());
        expect(queue.nextBatch(startMs)).toEqual([]);
        expect(queue.nextBatch(startMs + 60000)).toEqual([]);
    });

    test("fast-lane items are released immediately, before any budget has accrued", () => {
        const queue = new AutoImportQueue(60, createBackfillCursor());
        queue.addFastLaneItems([mediaItem("new-photo.jpg")]);

        expect(idsOf(queue.nextBatch(startMs))).toEqual(["new-photo.jpg"]);
    });

    test("the whole fast lane is released at once however large it is", () => {
        const queue = new AutoImportQueue(60, createBackfillCursor());
        queue.addFastLaneItems(mediaItems(500));

        expect(queue.nextBatch(startMs)).toHaveLength(500);
        expect(queue.hasPendingFastLane()).toBe(false);
    });

    test("fast-lane items are released ahead of backfill items in the same batch", () => {
        const queue = new AutoImportQueue(60, createBackfillCursor());

        // Start the clock, then let a minute of budget accrue so both lanes can release together.
        queue.nextBatch(startMs);
        queue.addBackfillItems([mediaItem("old-1"), mediaItem("old-2")], undefined);
        queue.addFastLaneItems([mediaItem("new-1")]);

        const batch = queue.nextBatch(startMs + 60000);

        expect(idsOf(batch)).toEqual(["new-1", "old-1", "old-2"]);
    });

    test("a new arrival does not wait behind a backfill that has no budget", () => {
        const queue = new AutoImportQueue(60, createBackfillCursor());
        queue.addBackfillItems(mediaItems(100), undefined);
        queue.nextBatch(startMs);

        // A photo is taken a tenth of a second later, long before the backfill earns its next item.
        queue.addFastLaneItems([mediaItem("new-photo.jpg")]);

        expect(idsOf(queue.nextBatch(startMs + 100))).toEqual(["new-photo.jpg"]);
    });

    test("no backfill item is released before the budget has earned one", () => {
        const queue = new AutoImportQueue(60, createBackfillCursor());
        queue.addBackfillItems(mediaItems(10), undefined);

        // The first call starts the clock and earns nothing.
        expect(queue.nextBatch(startMs)).toEqual([]);
        // Half a second later, at 60 per minute, half an item is not an item.
        expect(queue.nextBatch(startMs + 500)).toEqual([]);
    });

    test("the backfill respects the items-per-minute budget", () => {
        const queue = new AutoImportQueue(60, createBackfillCursor());
        queue.addBackfillItems(mediaItems(100), undefined);

        queue.nextBatch(startMs);

        // One second at 60 per minute is one item.
        expect(queue.nextBatch(startMs + 1000)).toHaveLength(1);
        // Ten more seconds is ten more items.
        expect(queue.nextBatch(startMs + 11000)).toHaveLength(10);
        // Nothing further until more time passes.
        expect(queue.nextBatch(startMs + 11000)).toHaveLength(0);
    });

    test("a faster rate releases proportionally more", () => {
        const queue = new AutoImportQueue(600, createBackfillCursor());
        queue.addBackfillItems(mediaItems(100), undefined);

        queue.nextBatch(startMs);
        expect(queue.nextBatch(startMs + 1000)).toHaveLength(10);
    });

    test("a long idle period does not release a huge burst", () => {
        const queue = new AutoImportQueue(60, createBackfillCursor());
        queue.addBackfillItems(mediaItems(1000), undefined);

        queue.nextBatch(startMs);

        // An hour has passed, but the budget is capped at one minute's worth.
        expect(queue.nextBatch(startMs + 3600000)).toHaveLength(60);
    });

    test("unused budget carries over rather than being lost", () => {
        const queue = new AutoImportQueue(60, createBackfillCursor());

        queue.nextBatch(startMs);
        // Five seconds pass with nothing to release, so five items of budget are banked.
        expect(queue.nextBatch(startMs + 5000)).toEqual([]);

        queue.addBackfillItems(mediaItems(10), undefined);
        expect(queue.nextBatch(startMs + 5000)).toHaveLength(5);
    });

    test("an item already queued is not queued a second time", () => {
        const queue = new AutoImportQueue(6000, createBackfillCursor());

        expect(queue.addBackfillItems([mediaItem("a.jpg"), mediaItem("b.jpg")], undefined)).toBe(2);
        expect(queue.addBackfillItems([mediaItem("a.jpg"), mediaItem("b.jpg"), mediaItem("c.jpg")], undefined)).toBe(1);

        queue.nextBatch(startMs);
        expect(idsOf(queue.nextBatch(startMs + 60000))).toEqual(["a.jpg", "b.jpg", "c.jpg"]);
    });

    test("an item already released is not queued again by a later listing", () => {
        const queue = new AutoImportQueue(6000, createBackfillCursor());
        queue.addBackfillItems([mediaItem("a.jpg")], undefined);

        queue.nextBatch(startMs);
        expect(idsOf(queue.nextBatch(startMs + 60000))).toEqual(["a.jpg"]);

        // The poll re-lists the folder and offers the same file again.
        expect(queue.addBackfillItems([mediaItem("a.jpg")], undefined)).toBe(0);
        expect(queue.nextBatch(startMs + 120000)).toEqual([]);
    });

    test("an item offered to both lanes is queued once", () => {
        const queue = new AutoImportQueue(6000, createBackfillCursor());

        expect(queue.addFastLaneItems([mediaItem("a.jpg")])).toBe(1);
        expect(queue.addBackfillItems([mediaItem("a.jpg")], undefined)).toBe(0);

        expect(idsOf(queue.nextBatch(startMs))).toEqual(["a.jpg"]);
        expect(queue.nextBatch(startMs + 60000)).toEqual([]);
    });

    test("the page cursor is not published until the page has been released in full", () => {
        const cursor = createBackfillCursor();
        const queue = new AutoImportQueue(60, cursor);
        queue.addBackfillItems(mediaItems(3), "page-2");

        expect(cursor.pageCursor).toBeUndefined();

        queue.nextBatch(startMs);
        queue.nextBatch(startMs + 2000);

        // Two of the three have been released, so resuming here would lose the third.
        expect(cursor.pageCursor).toBeUndefined();

        queue.nextBatch(startMs + 3000);

        expect(cursor.pageCursor).toBe("page-2");
        expect(queue.getBackfillCursor()).toBe(cursor);
    });

    test("a page that adds nothing new publishes its cursor straight away", () => {
        const cursor = createBackfillCursor();
        const queue = new AutoImportQueue(60, cursor);

        // Every item on this page has been seen already, so there is nothing to wait for.
        queue.addBackfillItems([mediaItem("a.jpg")], "page-2");
        queue.nextBatch(startMs);
        queue.nextBatch(startMs + 60000);
        expect(cursor.pageCursor).toBe("page-2");

        expect(queue.addBackfillItems([mediaItem("a.jpg")], "page-3")).toBe(0);
        expect(cursor.pageCursor).toBe("page-3");
    });

    test("the cursor is not moved by a fast-lane release", () => {
        const cursor = createBackfillCursor();
        const queue = new AutoImportQueue(60, cursor);
        queue.addFastLaneItems([mediaItem("new-photo.jpg")]);

        queue.nextBatch(startMs);

        expect(cursor.pageCursor).toBeUndefined();
        expect(cursor.completed).toBe(false);
    });

    test("a queue built from a saved cursor resumes mid-library", () => {
        const savedCursor = { pageCursor: "page-4", completed: false };
        const queue = new AutoImportQueue(6000, savedCursor);

        // The task resumes by asking the source for the page named by the cursor and offering it.
        queue.addBackfillItems([mediaItem("item-5"), mediaItem("item-6")], "page-5");
        queue.nextBatch(startMs);

        expect(idsOf(queue.nextBatch(startMs + 60000))).toEqual(["item-5", "item-6"]);
        expect(savedCursor.pageCursor).toBe("page-5");
        expect(savedCursor.completed).toBe(false);
    });

    test("pending backfill is reported so the task knows when to fetch the next page", () => {
        const queue = new AutoImportQueue(60, createBackfillCursor());
        expect(queue.hasPendingBackfill()).toBe(false);
        expect(queue.needsBackfillPage()).toBe(true);

        queue.addBackfillItems(mediaItems(2), "page-2");
        expect(queue.hasPendingBackfill()).toBe(true);
        expect(queue.pendingBackfillCount()).toBe(2);
        expect(queue.needsBackfillPage()).toBe(false);

        queue.nextBatch(startMs);
        queue.nextBatch(startMs + 60000);

        expect(queue.hasPendingBackfill()).toBe(false);
        expect(queue.pendingBackfillCount()).toBe(0);
        expect(queue.needsBackfillPage()).toBe(true);
    });

    test("a page with no next cursor finishes the backfill once it has been released", () => {
        const cursor = createBackfillCursor();
        const queue = new AutoImportQueue(60, cursor);

        queue.addBackfillItems(mediaItems(1), undefined);
        expect(queue.isBackfillComplete()).toBe(false);

        queue.nextBatch(startMs);
        queue.nextBatch(startMs + 60000);

        expect(queue.isBackfillComplete()).toBe(true);
        expect(cursor.completed).toBe(true);
        expect(queue.needsBackfillPage()).toBe(false);
    });

    test("an empty final page finishes the backfill immediately", () => {
        const cursor = createBackfillCursor();
        const queue = new AutoImportQueue(60, cursor);

        queue.addBackfillItems([], undefined);

        expect(queue.isBackfillComplete()).toBe(true);
        expect(cursor.completed).toBe(true);
    });

    test("time going backwards does not create budget", () => {
        const queue = new AutoImportQueue(60, createBackfillCursor());
        queue.addBackfillItems(mediaItems(10), undefined);

        queue.nextBatch(startMs);
        expect(queue.nextBatch(startMs - 60000)).toEqual([]);
    });
});
