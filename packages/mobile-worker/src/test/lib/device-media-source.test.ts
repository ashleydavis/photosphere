import { ALL_DEVICE_MEDIA_ALBUM_ID, IDeviceAlbumAutoImportSource } from "api/src/lib/auto-import-settings";
import { MediaSourceDeleteError } from "api/src/lib/media-source";
import { DEFAULT_POLL_INTERVAL_MS, DeviceMediaSource } from "../../lib/device-media-source";

//
// The photo library the source reads through is the native host bridge, which does not exist off a
// device. These tests install a scripted stand-in as globalThis.host, which is exactly what the
// engine installs on a real phone, so the shim under test is the real one.
//

//
// One page of the library, as the native side would describe it.
//
interface IScriptedPage {
    // The items in this page.
    items: {
        id: string,
        displayName: string,
        mimeType: string,
        size: number,
        createdAtMs: number,
        albumId: string,
    }[];

    // Where the next page starts, absent at the end of the library.
    nextCursor?: string;
}

//
// What the scripted host recorded, so a test can check what the source asked it to do.
//
interface IRecordedCalls {
    // The cursors mediaLibraryList was called with.
    cursors: string[];

    // The item ids mediaLibraryOpen was called with.
    opened: string[];

    // The item ids mediaLibraryClose was called with.
    closed: string[];

    // The batches mediaLibraryDelete was called with.
    deleted: string[][];
}

//
// Installs a scripted photo library as the native host, and returns what it records.
//
function installHost(pages: IScriptedPage[], deleteResult: { deletedIds: string[], failedIds: string[] }): IRecordedCalls {
    const recorded: IRecordedCalls = { cursors: [], opened: [], closed: [], deleted: [] };
    const remaining = [...pages];

    (globalThis as any).host = {
        mediaLibraryList: (cursor: string, _pageSize: number) => {
            recorded.cursors.push(cursor);
            const page = remaining.shift();
            return JSON.stringify(page ?? { items: [] });
        },
        mediaLibraryOpen: (itemId: string) => {
            recorded.opened.push(itemId);
            return `.media-tmp/${itemId}.jpg`;
        },
        mediaLibraryClose: (itemId: string) => {
            recorded.closed.push(itemId);
        },
        mediaLibraryDelete: (itemIdsJson: string) => {
            recorded.deleted.push(JSON.parse(itemIdsJson));
            return JSON.stringify(deleteResult);
        },
    };

    return recorded;
}

//
// One library item, with everything the source reads filled in.
//
function makeItem(id: string, albumId: string) {
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

//
// An item as the source hands it to the import.
//
const ONE_ITEM = {
    sourceId: "one",
    filePath: "",
    displayName: "one.jpg",
    contentType: "image/jpeg",
    size: 1024,
    createdAt: new Date(1700000000000),
};

describe("DeviceMediaSource", () => {

    afterEach(() => {
        delete (globalThis as any).host;
    });

    test("maps a library page into media items", async () => {
        installHost([{ items: [makeItem("one", "camera")], nextCursor: "10" }], { deletedIds: [], failedIds: [] });
        const source = new DeviceMediaSource(WHOLE_LIBRARY, 1000);

        const page = await source.listPage(undefined, 50);

        expect(page.nextCursor).toBe("10");
        expect(page.items).toHaveLength(1);
        expect(page.items[0].sourceId).toBe("one");
        expect(page.items[0].displayName).toBe("one.jpg");
        expect(page.items[0].contentType).toBe("image/jpeg");
        expect(page.items[0].size).toBe(1024);
        expect(page.items[0].createdAt.getTime()).toBe(1700000000000);
        // The path is only known after the item is opened, so there is nothing to read yet.
        expect(page.items[0].filePath).toBe("");
    });

    test("the reserved everything album takes the whole library rather than filtering by it", async () => {
        installHost([{ items: [makeItem("one", "camera"), makeItem("two", "screenshots")] }], { deletedIds: [], failedIds: [] });
        const source = new DeviceMediaSource(WHOLE_LIBRARY, 1000);

        const page = await source.listPage(undefined, 50);

        expect(page.items.map(item => item.sourceId)).toEqual(["one", "two"]);
    });

    test("keeps only the items in the named albums", async () => {
        installHost([{ items: [makeItem("one", "camera"), makeItem("two", "screenshots"), makeItem("three", "camera")] }], { deletedIds: [], failedIds: [] });
        const source = new DeviceMediaSource([{ type: "device-album", albumId: "camera" }], 1000);

        const page = await source.listPage(undefined, 50);

        expect(page.items.map(item => item.sourceId)).toEqual(["one", "three"]);
    });

    test("a page the album filter empties still yields its cursor so the walk carries on", async () => {
        installHost([{ items: [makeItem("one", "screenshots")], nextCursor: "10" }], { deletedIds: [], failedIds: [] });
        const source = new DeviceMediaSource([{ type: "device-album", albumId: "camera" }], 1000);

        const page = await source.listPage(undefined, 50);

        expect(page.items).toEqual([]);
        expect(page.nextCursor).toBe("10");
    });

    test("a missing cursor crosses the bridge as an empty string, which starts at the beginning", async () => {
        const recorded = installHost([{ items: [] }], { deletedIds: [], failedIds: [] });
        const source = new DeviceMediaSource(WHOLE_LIBRARY, 1000);

        await source.listPage(undefined, 50);

        expect(recorded.cursors).toEqual([""]);
    });

    test("a cursor is passed through unchanged", async () => {
        const recorded = installHost([{ items: [] }], { deletedIds: [], failedIds: [] });
        const source = new DeviceMediaSource(WHOLE_LIBRARY, 1000);

        await source.listPage("42", 50);

        expect(recorded.cursors).toEqual(["42"]);
    });

    test("opens and closes through the library", async () => {
        const recorded = installHost([], { deletedIds: [], failedIds: [] });
        const source = new DeviceMediaSource(WHOLE_LIBRARY, 1000);

        const openedPath = await source.openItem(ONE_ITEM);
        await source.closeItem(ONE_ITEM);

        expect(openedPath).toBe(".media-tmp/one.jpg");
        expect(recorded.opened).toEqual(["one"]);
        expect(recorded.closed).toEqual(["one"]);
    });

    test("a delete the library completed reports no failure", async () => {
        const recorded = installHost([], { deletedIds: ["one", "two"], failedIds: [] });
        const source = new DeviceMediaSource(WHOLE_LIBRARY, 1000);

        await source.deleteItems(["one", "two"]);

        expect(recorded.deleted).toEqual([["one", "two"]]);
    });

    test("a delete the library refused names the items that are still on the device", async () => {
        installHost([], { deletedIds: ["one"], failedIds: ["two"] });
        const source = new DeviceMediaSource(WHOLE_LIBRARY, 1000);

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
            installHost([], { deletedIds: [], failedIds: [] });
            const source = new DeviceMediaSource(WHOLE_LIBRARY, 1000);

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
            installHost([], { deletedIds: [], failedIds: [] });
            const source = new DeviceMediaSource(WHOLE_LIBRARY, 0);

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

    test("reaching for the library outside the worker says so, rather than looking like an empty library", async () => {
        delete (globalThis as any).host;
        const source = new DeviceMediaSource(WHOLE_LIBRARY, 1000);

        // An empty library and a missing bridge are indistinguishable to a caller that gets an empty
        // answer, and one of them silently backs up nothing.
        await expect(source.listPage(undefined, 50)).rejects.toThrow("host bridge");
    });
});
