import { AutoImportQueue } from "../../lib/auto-import-queue";
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
// Takes items from the queue at one instant until it gives nothing back, and returns their ids.
//
// The queue hands out one item at a time, so this is what a test about how much came out at a given
// moment asks. The limit is a backstop: a queue that never runs dry would otherwise hang the test.
//
function releasedAt(queue: AutoImportQueue, nowMs: number, limit: number = 10000): string[] {
    const released: string[] = [];
    while (released.length < limit) {
        const item = queue.nextItem(nowMs);
        if (item === undefined) {
            return released;
        }
        released.push(item.sourceId);
    }
    return released;
}

describe("AutoImportQueue", () => {

    const startMs = 1000000;

    test("nothing is released from an empty queue", () => {
        const queue = new AutoImportQueue(60);
        expect(queue.nextItem(startMs)).toBeUndefined();
        expect(queue.nextItem(startMs + 60000)).toBeUndefined();
    });

    test("fast-lane items are released immediately, before any budget has accrued", () => {
        const queue = new AutoImportQueue(60);
        queue.addFastLaneItems([mediaItem("new-photo.jpg")]);

        expect(queue.nextItem(startMs)!.sourceId).toBe("new-photo.jpg");
    });

    test("the whole fast lane is released without waiting for any budget", () => {
        // The pacing exists to keep a backfill of years of photos from taking the machine over. A
        // photo the user has just taken is not that, and they are watching for it.
        const queue = new AutoImportQueue(60);
        queue.addFastLaneItems(mediaItems(500));

        expect(releasedAt(queue, startMs)).toHaveLength(500);
        expect(queue.hasPendingFastLane()).toBe(false);
    });

    test("the fast lane comes out before the backfill, whatever budget the backfill has", () => {
        const queue = new AutoImportQueue(60);

        // Start the clock, then let a minute of budget accrue so the backfill could release too.
        queue.nextItem(startMs);
        queue.addBackfillItems([mediaItem("old-1"), mediaItem("old-2")]);
        queue.addFastLaneItems([mediaItem("new-1")]);

        expect(releasedAt(queue, startMs + 60000)).toEqual(["new-1", "old-1", "old-2"]);
    });

    test("an arrival is never behind more than the one backfill item already released", () => {
        // This is what handing out one item at a time buys: the lane is looked at again before every
        // single import, so a photo taken during a backfill of ten thousand is next, not last.
        const queue = new AutoImportQueue(6000);
        queue.addBackfillItems(mediaItems(100));
        queue.nextItem(startMs);

        expect(queue.nextItem(startMs + 60000)!.sourceId).toBe("item-0");

        queue.addFastLaneItems([mediaItem("new-photo.jpg")]);

        expect(queue.nextItem(startMs + 60000)!.sourceId).toBe("new-photo.jpg");
    });

    test("a new arrival does not wait behind a backfill that has no budget", () => {
        const queue = new AutoImportQueue(60);
        queue.addBackfillItems(mediaItems(100));
        queue.nextItem(startMs);

        // A photo is taken a tenth of a second later, long before the backfill earns its next item.
        queue.addFastLaneItems([mediaItem("new-photo.jpg")]);

        expect(queue.nextItem(startMs + 100)!.sourceId).toBe("new-photo.jpg");
    });

    test("no backfill item is released before the budget has earned one", () => {
        const queue = new AutoImportQueue(60);
        queue.addBackfillItems(mediaItems(10));

        // The first call starts the clock and earns nothing.
        expect(queue.nextItem(startMs)).toBeUndefined();
        // Half a second later, at 60 per minute, half an item is not an item.
        expect(queue.nextItem(startMs + 500)).toBeUndefined();
    });

    test("the backfill respects the items-per-minute budget", () => {
        const queue = new AutoImportQueue(60);
        queue.addBackfillItems(mediaItems(100));

        queue.nextItem(startMs);

        // One second at 60 per minute is one item, and no more until more time passes.
        expect(releasedAt(queue, startMs + 1000)).toHaveLength(1);
        // Ten more seconds earns ten more.
        expect(releasedAt(queue, startMs + 11000)).toHaveLength(10);
        expect(releasedAt(queue, startMs + 11000)).toHaveLength(0);
    });

    test("a faster rate releases proportionally more", () => {
        const queue = new AutoImportQueue(600);
        queue.addBackfillItems(mediaItems(100));

        queue.nextItem(startMs);

        // A second at 600 per minute earns ten items.
        expect(releasedAt(queue, startMs + 1000)).toHaveLength(10);
    });

    test("a long idle period does not release a huge burst", () => {
        const queue = new AutoImportQueue(60);
        queue.addBackfillItems(mediaItems(1000));

        queue.nextItem(startMs);

        // An hour has passed, but the budget is still capped at one minute's worth.
        expect(releasedAt(queue, startMs + 3600000)).toHaveLength(60);
    });

    test("unused budget carries over rather than being lost", () => {
        const queue = new AutoImportQueue(60);

        queue.nextItem(startMs);
        // Five seconds pass with nothing to release, so five items of budget are banked.
        expect(queue.nextItem(startMs + 5000)).toBeUndefined();

        queue.addBackfillItems(mediaItems(10));
        expect(releasedAt(queue, startMs + 5000)).toHaveLength(5);
    });

    test("an item already queued is not queued a second time", () => {
        const queue = new AutoImportQueue(6000);

        expect(queue.addBackfillItems([mediaItem("a.jpg"), mediaItem("b.jpg")])).toBe(2);
        expect(queue.addBackfillItems([mediaItem("a.jpg"), mediaItem("b.jpg"), mediaItem("c.jpg")])).toBe(1);

        queue.nextItem(startMs);
        expect(releasedAt(queue, startMs + 60000)).toEqual(["a.jpg", "b.jpg", "c.jpg"]);
    });

    test("an item already released is not queued again by a later listing", () => {
        const queue = new AutoImportQueue(6000);
        queue.addBackfillItems([mediaItem("a.jpg")]);

        queue.nextItem(startMs);
        expect(releasedAt(queue, startMs + 60000)).toEqual(["a.jpg"]);

        // The poll re-lists the folder and offers the same file again.
        expect(queue.addBackfillItems([mediaItem("a.jpg")])).toBe(0);
        expect(queue.nextItem(startMs + 120000)).toBeUndefined();
    });

    test("an item offered to both lanes is queued once", () => {
        const queue = new AutoImportQueue(6000);

        expect(queue.addFastLaneItems([mediaItem("a.jpg")])).toBe(1);
        expect(queue.addBackfillItems([mediaItem("a.jpg")])).toBe(0);

        expect(releasedAt(queue, startMs)).toEqual(["a.jpg"]);
        expect(queue.nextItem(startMs + 60000)).toBeUndefined();
    });

    test("pending backfill is reported so the run knows when to fetch the next page", () => {
        const queue = new AutoImportQueue(60);
        expect(queue.hasPendingBackfill()).toBe(false);

        queue.addBackfillItems(mediaItems(2));
        expect(queue.hasPendingBackfill()).toBe(true);
        expect(queue.pendingBackfillCount()).toBe(2);

        queue.nextItem(startMs);
        releasedAt(queue, startMs + 60000);

        expect(queue.hasPendingBackfill()).toBe(false);
        expect(queue.pendingBackfillCount()).toBe(0);
    });

    test("time going backwards does not create budget", () => {
        const queue = new AutoImportQueue(60);
        queue.addBackfillItems(mediaItems(10));

        queue.nextItem(startMs);
        expect(queue.nextItem(startMs - 60000)).toBeUndefined();
    });
});
