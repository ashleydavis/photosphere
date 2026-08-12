import {
    IImportedSourceItem,
    runSourceCleanup,
    selectConfirmedForCleanup,
} from "../../lib/source-cleanup";
import {
    IMediaItem,
    IMediaSource,
    IMediaSourceChangedCallback,
    IMediaSourceListPage,
    IMediaSourceUnsubscribe,
    MediaSourceDeleteError,
} from "../../lib/media-source";

//
// A media source that records the delete requests it was given and answers however the test says.
// This is a test double for the source interface, not for anything under test: the code under test
// is the selection and the batching.
//
class RecordingMediaSource implements IMediaSource {
    // Each batch of source ids it was asked to delete, in order.
    readonly deleteRequests: string[][] = [];

    // Ids it refuses, reported through MediaSourceDeleteError.
    refusedSourceIds = new Set<string>();

    // Ids whose batch throws something other than a delete error, standing in for a source that
    // failed in a way that says nothing about which items went.
    unexplainedFailureSourceIds = new Set<string>();

    async listPage(cursor: string | undefined, pageSize: number): Promise<IMediaSourceListPage> {
        return { items: [], nextCursor: undefined };
    }

    watch(onChanged: IMediaSourceChangedCallback): IMediaSourceUnsubscribe {
        return () => {};
    }

    async exportItem(item: IMediaItem): Promise<string> {
        return item.filePath;
    }

    async releaseItem(item: IMediaItem): Promise<void> {
    }

    async deleteItems(sourceIds: string[]): Promise<void> {
        this.deleteRequests.push([...sourceIds]);

        if (sourceIds.some(sourceId => this.unexplainedFailureSourceIds.has(sourceId))) {
            throw new Error("The photo library is unavailable.");
        }

        const refused = sourceIds.filter(sourceId => this.refusedSourceIds.has(sourceId));
        if (refused.length > 0) {
            throw new MediaSourceDeleteError("Refused.", refused);
        }
    }
}

//
// An imported item and the hash the import computed for it.
//
function importedItem(sourceId: string, contentHash: string): IImportedSourceItem {
    return { sourceId, contentHash };
}

describe("selectConfirmedForCleanup", () => {

    test("selects only the items whose hash is in the database", () => {
        const imported = [
            importedItem("/photos/a.jpg", "aaaa"),
            importedItem("/photos/b.jpg", "bbbb"),
            importedItem("/photos/c.jpg", "cccc"),
        ];
        const databaseHashes = new Set(["aaaa", "cccc"]);

        expect(selectConfirmedForCleanup(imported, databaseHashes)).toEqual(["/photos/a.jpg", "/photos/c.jpg"]);
    });

    test("selects nothing when the database holds none of the hashes", () => {
        const imported = [importedItem("/photos/a.jpg", "aaaa")];
        expect(selectConfirmedForCleanup(imported, new Set(["zzzz"]))).toEqual([]);
    });

    test("selects nothing from an empty database", () => {
        const imported = [importedItem("/photos/a.jpg", "aaaa")];
        expect(selectConfirmedForCleanup(imported, new Set<string>())).toEqual([]);
    });

    test("matches hashes regardless of letter case", () => {
        const imported = [importedItem("/photos/a.jpg", "AABBCC")];
        expect(selectConfirmedForCleanup(imported, new Set(["aabbcc"]))).toEqual(["/photos/a.jpg"]);
    });

    test("an item with no hash is never selected", () => {
        const imported = [importedItem("/photos/a.jpg", "")];
        expect(selectConfirmedForCleanup(imported, new Set(["aaaa", ""]))).toEqual([]);
    });

    test("a source id appears once even when imported twice", () => {
        const imported = [
            importedItem("/photos/a.jpg", "aaaa"),
            importedItem("/photos/a.jpg", "aaaa"),
        ];
        expect(selectConfirmedForCleanup(imported, new Set(["aaaa"]))).toEqual(["/photos/a.jpg"]);
    });

    test("selects nothing from an empty import", () => {
        expect(selectConfirmedForCleanup([], new Set(["aaaa"]))).toEqual([]);
    });
});

describe("runSourceCleanup", () => {

    test("deletes everything in one request when it fits in a batch", async () => {
        const source = new RecordingMediaSource();

        const result = await runSourceCleanup(source, ["a", "b", "c"], 50);

        expect(source.deleteRequests).toEqual([["a", "b", "c"]]);
        expect(result.deletedSourceIds).toEqual(["a", "b", "c"]);
        expect(result.failedSourceIds).toEqual([]);
    });

    test("splits the ids into batches", async () => {
        const source = new RecordingMediaSource();

        const result = await runSourceCleanup(source, ["a", "b", "c", "d", "e"], 2);

        expect(source.deleteRequests).toEqual([["a", "b"], ["c", "d"], ["e"]]);
        expect(result.deletedSourceIds).toEqual(["a", "b", "c", "d", "e"]);
    });

    test("asks for nothing when there is nothing to delete", async () => {
        const source = new RecordingMediaSource();

        const result = await runSourceCleanup(source, [], 50);

        expect(source.deleteRequests).toEqual([]);
        expect(result.deletedSourceIds).toEqual([]);
    });

    test("reports the ids the source refused and keeps the rest as deleted", async () => {
        const source = new RecordingMediaSource();
        source.refusedSourceIds.add("b");

        const result = await runSourceCleanup(source, ["a", "b", "c"], 50);

        expect(result.deletedSourceIds).toEqual(["a", "c"]);
        expect(result.failedSourceIds).toEqual(["b"]);
    });

    test("a batch that fails without saying what happened counts as none deleted", async () => {
        const source = new RecordingMediaSource();
        source.unexplainedFailureSourceIds.add("b");

        const result = await runSourceCleanup(source, ["a", "b", "c"], 50);

        expect(result.deletedSourceIds).toEqual([]);
        expect(result.failedSourceIds).toEqual(["a", "b", "c"]);
    });

    test("a refused batch does not stop the batches after it", async () => {
        const source = new RecordingMediaSource();
        source.refusedSourceIds.add("a");

        const result = await runSourceCleanup(source, ["a", "b", "c", "d"], 2);

        expect(source.deleteRequests).toEqual([["a", "b"], ["c", "d"]]);
        expect(result.deletedSourceIds).toEqual(["b", "c", "d"]);
        expect(result.failedSourceIds).toEqual(["a"]);
    });

    test("a batch size below one is refused rather than looping forever", async () => {
        const source = new RecordingMediaSource();

        await expect(runSourceCleanup(source, ["a"], 0)).rejects.toThrow(/batch size/i);
    });
});
