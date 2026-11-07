import { AutoImportQueue } from "../../lib/auto-import-queue";
import { IMediaItem } from "../../lib/media-source";

//
// Makes a media item with the given source id. The other fields do not matter here, which is the
// point: this class decides order, nothing else.
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
// Takes items from the queue until it gives nothing back, and returns their ids.
//
// The limit is a backstop: a queue that never ran dry would otherwise hang the test.
//
function drain(queue: AutoImportQueue, limit: number = 10000): string[] {
    const released: string[] = [];
    while (released.length < limit) {
        const item = queue.nextItem();
        if (item === undefined) {
            return released;
        }
        released.push(item.sourceId);
    }

    return released;
}

describe("AutoImportQueue", () => {

    test("nothing is released from an empty queue", () => {
        const queue = new AutoImportQueue();

        expect(queue.nextItem()).toBeUndefined();
    });

    test("everything offered comes straight out, with nothing held back", () => {
        // The whole point of removing the rate limit: a library offered to the queue is available
        // as fast as the import can take it, rather than at a fixed number a minute.
        const queue = new AutoImportQueue();
        queue.addItems(mediaItems(500));

        expect(drain(queue)).toHaveLength(500);
    });

    test("items come out in the order they were offered", () => {
        const queue = new AutoImportQueue();
        queue.addItems(mediaItems(3));

        expect(drain(queue)).toEqual(["item-0", "item-1", "item-2"]);
    });

    test("a photo offered later is still released, behind what was already waiting", () => {
        // A photo taken during an import: it goes to the back of what is queued, and because items
        // come out one at a time it is never behind more than the one being imported now.
        const queue = new AutoImportQueue();
        queue.addItems(mediaItems(2));
        queue.addItems([mediaItem("just-taken.jpg")]);

        expect(drain(queue)).toEqual(["item-0", "item-1", "just-taken.jpg"]);
    });

    test("an item already queued is not queued a second time", () => {
        // Every run reads the source from the beginning, so the same items are offered over and
        // over. Without this a library would be imported once per page fetch.
        const queue = new AutoImportQueue();

        expect(queue.addItems(mediaItems(3))).toBe(3);
        expect(queue.addItems(mediaItems(3))).toBe(0);
        expect(drain(queue)).toEqual(["item-0", "item-1", "item-2"]);
    });

    test("an item is not queued again after it has been released", () => {
        const queue = new AutoImportQueue();
        queue.addItems([mediaItem("photo.jpg")]);
        queue.nextItem();

        expect(queue.addItems([mediaItem("photo.jpg")])).toBe(0);
        expect(queue.nextItem()).toBeUndefined();
    });

    test("what is waiting is reported until it has all been released", () => {
        const queue = new AutoImportQueue();
        expect(queue.hasPending()).toBe(false);
        expect(queue.pendingCount()).toBe(0);

        queue.addItems(mediaItems(2));
        expect(queue.hasPending()).toBe(true);
        expect(queue.pendingCount()).toBe(2);

        queue.nextItem();
        expect(queue.pendingCount()).toBe(1);

        queue.nextItem();
        expect(queue.hasPending()).toBe(false);
        expect(queue.pendingCount()).toBe(0);
    });
});
