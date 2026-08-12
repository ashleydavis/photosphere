import { ALL_DEVICE_MEDIA_ALBUM_ID, IDeviceAlbumAutoImportSource } from "api/src/lib/auto-import-settings";
import { MediaSourceDeleteError } from "api/src/lib/media-source";
import {
    IDeviceMediaLibrary,
    IDeviceMediaLibraryDeleteResult,
    IDeviceMediaLibraryItem,
    IDeviceMediaLibraryPage,
} from "../lib/device-media-library";
import { DEFAULT_POLL_INTERVAL_MS, DeviceMediaSource } from "../lib/device-media-source";

//
// A photo library that answers from a script, so the source can be tested with no device.
//
class FakeMediaLibrary implements IDeviceMediaLibrary {
    // The pages to hand out, in order.
    private readonly pages: IDeviceMediaLibraryPage[];

    // The cursors listPage was called with, so a test can check the walk.
    readonly requestedCursors: (string | undefined)[] = [];

    // The item ids export was called with.
    readonly exportedIds: string[] = [];

    // The item ids release was called with.
    readonly releasedIds: string[] = [];

    // The batches delete was called with.
    readonly deletedBatches: string[][] = [];

    // What delete should report back.
    deleteResult: IDeviceMediaLibraryDeleteResult = { deletedIds: [], failedIds: [] };

    constructor(pages: IDeviceMediaLibraryPage[]) {
        this.pages = pages;
    }

    async listPage(cursor: string | undefined, _pageSize: number): Promise<IDeviceMediaLibraryPage> {
        this.requestedCursors.push(cursor);
        const page = this.pages.shift();
        return page ?? { items: [] };
    }

    async exportItem(itemId: string): Promise<string> {
        this.exportedIds.push(itemId);
        return `.media-tmp/${itemId}.jpg`;
    }

    async releaseItem(itemId: string): Promise<void> {
        this.releasedIds.push(itemId);
    }

    async deleteItems(itemIds: string[]): Promise<IDeviceMediaLibraryDeleteResult> {
        this.deletedBatches.push(itemIds);
        return this.deleteResult;
    }
}

//
// One library item, with everything the source reads filled in.
//
function makeItem(id: string, albumId: string): IDeviceMediaLibraryItem {
    return {
        id,
        displayName: `${id}.jpg`,
        mimeType: "image/jpeg",
        size: 1024,
        createdAtMs: 1700000000000,
        albumId,
    };
}

//
// The whole library, which is what is watched before the user picks albums.
//
const WHOLE_LIBRARY: IDeviceAlbumAutoImportSource[] = [
    { type: "device-album", albumId: ALL_DEVICE_MEDIA_ALBUM_ID },
];

describe("DeviceMediaSource", () => {

    test("maps a library page into media items", async () => {
        const library = new FakeMediaLibrary([
            { items: [makeItem("one", "camera")], nextCursor: "10" },
        ]);
        const source = new DeviceMediaSource(WHOLE_LIBRARY, 1000, library);

        const page = await source.listPage(undefined, 50);

        expect(page.nextCursor).toBe("10");
        expect(page.items).toHaveLength(1);
        expect(page.items[0].sourceId).toBe("one");
        expect(page.items[0].displayName).toBe("one.jpg");
        expect(page.items[0].contentType).toBe("image/jpeg");
        expect(page.items[0].size).toBe(1024);
        expect(page.items[0].createdAt.getTime()).toBe(1700000000000);
        // The path is only known after the item is exported, so there is nothing to read yet.
        expect(page.items[0].filePath).toBe("");
    });

    test("the reserved everything album takes the whole library rather than filtering by it", async () => {
        const library = new FakeMediaLibrary([
            { items: [makeItem("one", "camera"), makeItem("two", "screenshots")] },
        ]);
        const source = new DeviceMediaSource(WHOLE_LIBRARY, 1000, library);

        const page = await source.listPage(undefined, 50);

        expect(page.items.map(item => item.sourceId)).toEqual(["one", "two"]);
    });

    test("keeps only the items in the named albums", async () => {
        const library = new FakeMediaLibrary([
            { items: [makeItem("one", "camera"), makeItem("two", "screenshots"), makeItem("three", "camera")] },
        ]);
        const source = new DeviceMediaSource([{ type: "device-album", albumId: "camera" }], 1000, library);

        const page = await source.listPage(undefined, 50);

        expect(page.items.map(item => item.sourceId)).toEqual(["one", "three"]);
    });

    test("a page the album filter empties still yields its cursor so the walk carries on", async () => {
        const library = new FakeMediaLibrary([
            { items: [makeItem("one", "screenshots")], nextCursor: "10" },
        ]);
        const source = new DeviceMediaSource([{ type: "device-album", albumId: "camera" }], 1000, library);

        const page = await source.listPage(undefined, 50);

        expect(page.items).toEqual([]);
        expect(page.nextCursor).toBe("10");
    });

    test("passes the cursor straight through to the library", async () => {
        const library = new FakeMediaLibrary([{ items: [] }]);
        const source = new DeviceMediaSource(WHOLE_LIBRARY, 1000, library);

        await source.listPage("42", 50);

        expect(library.requestedCursors).toEqual(["42"]);
    });

    test("exports and releases through the library", async () => {
        const library = new FakeMediaLibrary([]);
        const source = new DeviceMediaSource(WHOLE_LIBRARY, 1000, library);
        const item = {
            sourceId: "one",
            filePath: "",
            displayName: "one.jpg",
            contentType: "image/jpeg",
            size: 1024,
            createdAt: new Date(1700000000000),
        };

        const exportedPath = await source.exportItem(item);
        await source.releaseItem(item);

        expect(exportedPath).toBe(".media-tmp/one.jpg");
        expect(library.exportedIds).toEqual(["one"]);
        expect(library.releasedIds).toEqual(["one"]);
    });

    test("a delete the library completed reports no failure", async () => {
        const library = new FakeMediaLibrary([]);
        library.deleteResult = { deletedIds: ["one", "two"], failedIds: [] };
        const source = new DeviceMediaSource(WHOLE_LIBRARY, 1000, library);

        await source.deleteItems(["one", "two"]);

        expect(library.deletedBatches).toEqual([["one", "two"]]);
    });

    test("a delete the library refused names the items that are still on the device", async () => {
        const library = new FakeMediaLibrary([]);
        library.deleteResult = { deletedIds: ["one"], failedIds: ["two"] };
        const source = new DeviceMediaSource(WHOLE_LIBRARY, 1000, library);

        await expect(source.deleteItems(["one", "two"])).rejects.toThrow(MediaSourceDeleteError);

        try {
            await source.deleteItems(["one", "two"]);
        }
        catch (error) {
            expect((error as MediaSourceDeleteError).sourceIds).toEqual(["two"]);
        }
    });

    test("watching re-lists on the poll interval until it is unsubscribed", () => {
        jest.useFakeTimers();
        try {
            const library = new FakeMediaLibrary([]);
            const source = new DeviceMediaSource(WHOLE_LIBRARY, 1000, library);

            let changes = 0;
            const unsubscribe = source.watch(() => { changes += 1; });

            jest.advanceTimersByTime(3000);
            expect(changes).toBe(3);

            unsubscribe();
            jest.advanceTimersByTime(3000);
            expect(changes).toBe(3);
        }
        finally {
            jest.useRealTimers();
        }
    });

    test("a poll interval of zero falls back to the default rather than polling in a tight loop", () => {
        jest.useFakeTimers();
        try {
            const library = new FakeMediaLibrary([]);
            const source = new DeviceMediaSource(WHOLE_LIBRARY, 0, library);

            let changes = 0;
            const unsubscribe = source.watch(() => { changes += 1; });

            jest.advanceTimersByTime(DEFAULT_POLL_INTERVAL_MS - 1);
            expect(changes).toBe(0);

            jest.advanceTimersByTime(1);
            expect(changes).toBe(1);

            unsubscribe();
        }
        finally {
            jest.useRealTimers();
        }
    });
});
