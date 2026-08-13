import * as fsSync from "fs";
import * as path from "path";
import { createTestTempDir } from "node-utils";
import { RandomUuidGenerator } from "utils";
import { IFolderAutoImportSource } from "api";
import { FolderMediaSource } from "../../lib/folder-media-source";
import { IMediaItem, MediaSourceDeleteError } from "../../lib/media-source";

//
// Makes a folder source entry for a path.
//
function folderSource(folderPath: string, recurse: boolean): IFolderAutoImportSource {
    return { type: "folder", path: folderPath, recurse };
}

//
// Writes a file with some bytes in it, creating parent directories as needed.
//
function writeFile(filePath: string, contents: string): void {
    fsSync.mkdirSync(path.dirname(filePath), { recursive: true });
    fsSync.writeFileSync(filePath, contents);
}

//
// Drains every page of a source into one list, so a test can assert on the whole listing.
//
async function listAll(source: FolderMediaSource, pageSize: number): Promise<IMediaItem[]> {
    const items: IMediaItem[] = [];
    let cursor: string | undefined = undefined;
    let pages = 0;
    do {
        const page: { items: IMediaItem[], nextCursor: string | undefined } = await source.listPage(cursor, pageSize);
        items.push(...page.items);
        cursor = page.nextCursor;
        pages += 1;
        if (pages > 100) {
            throw new Error("Paging did not terminate.");
        }
    } while (cursor !== undefined);
    return items;
}

//
// Waits for a condition to become true, polling until a deadline. Used instead of a fixed sleep so
// the watcher tests do not depend on how loaded the machine is.
//
async function waitFor(condition: () => boolean, timeoutMs: number): Promise<void> {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
        if (condition()) {
            return;
        }
        await new Promise<void>(resolve => setTimeout(resolve, 10));
    }
    throw new Error("Timed out waiting for the condition.");
}

describe("FolderMediaSource", () => {

    let tempDir: string;
    let photosDir: string;
    let sessionTempDir: string;
    const uuidGenerator = new RandomUuidGenerator();

    beforeEach(() => {
        tempDir = createTestTempDir("folder-media-source");
        photosDir = path.join(tempDir, "photos");
        sessionTempDir = path.join(tempDir, "session");
        fsSync.mkdirSync(photosDir, { recursive: true });
        fsSync.mkdirSync(sessionTempDir, { recursive: true });
    });

    test("lists the media files in a folder", async () => {
        writeFile(path.join(photosDir, "a.jpg"), "first");
        writeFile(path.join(photosDir, "b.png"), "second");

        const source = new FolderMediaSource([folderSource(photosDir, true)], 60000, sessionTempDir, uuidGenerator);
        const page = await source.listPage(undefined, 10);

        expect(page.items.map(item => item.displayName)).toEqual(["a.jpg", "b.png"]);
        expect(page.nextCursor).toBeUndefined();
    });

    test("reports the details of each item", async () => {
        const filePath = path.join(photosDir, "a.jpg");
        writeFile(filePath, "0123456789");

        const source = new FolderMediaSource([folderSource(photosDir, true)], 60000, sessionTempDir, uuidGenerator);
        const page = await source.listPage(undefined, 10);

        expect(page.items).toHaveLength(1);
        const item = page.items[0];
        expect(item.sourceId).toBe(filePath);
        expect(item.filePath).toBe(filePath);
        expect(item.displayName).toBe("a.jpg");
        expect(item.contentType).toBe("image/jpeg");
        expect(item.size).toBe(10);
        expect(Number.isFinite(item.createdAt.getTime())).toBe(true);
    });

    test("filters out files that are not media", async () => {
        writeFile(path.join(photosDir, "a.jpg"), "photo");
        writeFile(path.join(photosDir, "notes.txt"), "text");
        writeFile(path.join(photosDir, "drawing.svg"), "vector");

        const source = new FolderMediaSource([folderSource(photosDir, true)], 60000, sessionTempDir, uuidGenerator);
        const items = await listAll(source, 10);

        expect(items.map(item => item.displayName)).toEqual(["a.jpg"]);
    });

    test("pages through a listing", async () => {
        for (const name of ["a.jpg", "b.jpg", "c.jpg", "d.jpg", "e.jpg"]) {
            writeFile(path.join(photosDir, name), name);
        }

        const source = new FolderMediaSource([folderSource(photosDir, true)], 60000, sessionTempDir, uuidGenerator);

        const firstPage = await source.listPage(undefined, 2);
        expect(firstPage.items.map(item => item.displayName)).toEqual(["a.jpg", "b.jpg"]);
        expect(firstPage.nextCursor).toBe(path.join(photosDir, "b.jpg"));

        const secondPage = await source.listPage(firstPage.nextCursor, 2);
        expect(secondPage.items.map(item => item.displayName)).toEqual(["c.jpg", "d.jpg"]);

        const thirdPage = await source.listPage(secondPage.nextCursor, 2);
        expect(thirdPage.items.map(item => item.displayName)).toEqual(["e.jpg"]);
        expect(thirdPage.nextCursor).toBeUndefined();
    });

    test("every item is listed exactly once across pages", async () => {
        const names = ["a.jpg", "b.jpg", "c.jpg", "d.jpg", "e.jpg", "f.jpg", "g.jpg"];
        for (const name of names) {
            writeFile(path.join(photosDir, name), name);
        }

        const source = new FolderMediaSource([folderSource(photosDir, true)], 60000, sessionTempDir, uuidGenerator);
        const items = await listAll(source, 3);

        expect(items.map(item => item.displayName)).toEqual(names);
    });

    test("resumes after a cursor whose item has been deleted, without going back to the start", async () => {
        for (const name of ["a.jpg", "b.jpg", "c.jpg", "d.jpg"]) {
            writeFile(path.join(photosDir, name), name);
        }

        const source = new FolderMediaSource([folderSource(photosDir, true)], 60000, sessionTempDir, uuidGenerator);
        const firstPage = await source.listPage(undefined, 2);
        expect(firstPage.items.map(item => item.displayName)).toEqual(["a.jpg", "b.jpg"]);

        // The item the cursor names is gone by the time the next page is asked for, which is the
        // ordinary case when cleanup deletes source files as they are imported. A fresh source
        // stands in for the task being restarted and resuming from the persisted cursor, so there
        // is no cached listing to find the missing item in.
        fsSync.unlinkSync(path.join(photosDir, "b.jpg"));

        const resumedSource = new FolderMediaSource([folderSource(photosDir, true)], 60000, sessionTempDir, uuidGenerator);
        const nextPage = await resumedSource.listPage(path.join(photosDir, "b.jpg"), 10);
        expect(nextPage.items.map(item => item.displayName)).toEqual(["c.jpg", "d.jpg"]);
    });

    test("a cursor past the end of the listing yields nothing", async () => {
        writeFile(path.join(photosDir, "a.jpg"), "one");

        const source = new FolderMediaSource([folderSource(photosDir, true)], 60000, sessionTempDir, uuidGenerator);
        const page = await source.listPage(path.join(photosDir, "zz.jpg"), 10);

        expect(page.items).toEqual([]);
        expect(page.nextCursor).toBeUndefined();
    });

    test("a recursive folder includes files in subfolders", async () => {
        writeFile(path.join(photosDir, "a.jpg"), "top");
        writeFile(path.join(photosDir, "holiday", "b.jpg"), "nested");

        const source = new FolderMediaSource([folderSource(photosDir, true)], 60000, sessionTempDir, uuidGenerator);
        const items = await listAll(source, 10);

        expect(items.map(item => item.displayName).sort()).toEqual(["a.jpg", "b.jpg"]);
    });

    test("a non-recursive folder takes only the files directly in it", async () => {
        writeFile(path.join(photosDir, "a.jpg"), "top");
        writeFile(path.join(photosDir, "holiday", "b.jpg"), "nested");

        const source = new FolderMediaSource([folderSource(photosDir, false)], 60000, sessionTempDir, uuidGenerator);
        const items = await listAll(source, 10);

        expect(items.map(item => item.displayName)).toEqual(["a.jpg"]);
    });

    test("lists across several folders", async () => {
        const otherDir = path.join(tempDir, "more-photos");
        writeFile(path.join(photosDir, "a.jpg"), "one");
        writeFile(path.join(otherDir, "b.jpg"), "two");

        const source = new FolderMediaSource(
            [folderSource(photosDir, true), folderSource(otherDir, true)],
            60000,
            sessionTempDir,
            uuidGenerator
        );
        const items = await listAll(source, 10);

        expect(items.map(item => item.displayName).sort()).toEqual(["a.jpg", "b.jpg"]);
    });

    test("a folder that does not exist yields nothing rather than throwing", async () => {
        const source = new FolderMediaSource([folderSource(path.join(tempDir, "absent"), true)], 60000, sessionTempDir, uuidGenerator);
        const page = await source.listPage(undefined, 10);

        expect(page.items).toEqual([]);
        expect(page.nextCursor).toBeUndefined();
    });

    test("openItem returns the file path unchanged and closeItem does nothing", async () => {
        const filePath = path.join(photosDir, "a.jpg");
        writeFile(filePath, "photo");

        const source = new FolderMediaSource([folderSource(photosDir, true)], 60000, sessionTempDir, uuidGenerator);
        const page = await source.listPage(undefined, 10);

        expect(await source.openItem(page.items[0])).toBe(filePath);
        await source.closeItem(page.items[0]);
        expect(fsSync.existsSync(filePath)).toBe(true);
    });

    test("the poll reports a change", async () => {
        writeFile(path.join(photosDir, "a.jpg"), "photo");

        const source = new FolderMediaSource([folderSource(photosDir, true)], 30, sessionTempDir, uuidGenerator);
        let changes = 0;
        const unsubscribe = source.watch(() => {
            changes += 1;
        });

        try {
            await waitFor(() => changes > 0, 5000);
        }
        finally {
            unsubscribe();
        }

        expect(changes).toBeGreaterThan(0);
    });

    test("a new file shows up in a listing taken after a change was reported", async () => {
        writeFile(path.join(photosDir, "a.jpg"), "photo");

        const source = new FolderMediaSource([folderSource(photosDir, true)], 30, sessionTempDir, uuidGenerator);
        expect((await source.listPage(undefined, 10)).items).toHaveLength(1);

        let changes = 0;
        const unsubscribe = source.watch(() => {
            changes += 1;
        });

        try {
            writeFile(path.join(photosDir, "b.jpg"), "another");
            await waitFor(() => changes > 0, 5000);
            const items = await listAll(source, 10);
            expect(items.map(item => item.displayName)).toEqual(["a.jpg", "b.jpg"]);
        }
        finally {
            unsubscribe();
        }
    });

    test("unsubscribing stops the change reports", async () => {
        writeFile(path.join(photosDir, "a.jpg"), "photo");

        const source = new FolderMediaSource([folderSource(photosDir, true)], 20, sessionTempDir, uuidGenerator);
        let changes = 0;
        const unsubscribe = source.watch(() => {
            changes += 1;
        });

        try {
            await waitFor(() => changes > 0, 5000);
        }
        finally {
            unsubscribe();
        }

        const changesAtUnsubscribe = changes;
        await new Promise<void>(resolve => setTimeout(resolve, 200));

        expect(changes).toBe(changesAtUnsubscribe);
    });

    test("deleteItems removes the source files", async () => {
        const firstPath = path.join(photosDir, "a.jpg");
        const secondPath = path.join(photosDir, "b.jpg");
        writeFile(firstPath, "one");
        writeFile(secondPath, "two");

        const source = new FolderMediaSource([folderSource(photosDir, true)], 60000, sessionTempDir, uuidGenerator);
        const items = await listAll(source, 10);

        await source.deleteItems([items[0].sourceId]);

        expect(fsSync.existsSync(firstPath)).toBe(false);
        expect(fsSync.existsSync(secondPath)).toBe(true);
    });

    test("deleting an item that is already gone is not an error", async () => {
        const filePath = path.join(photosDir, "a.jpg");
        writeFile(filePath, "one");

        const source = new FolderMediaSource([folderSource(photosDir, true)], 60000, sessionTempDir, uuidGenerator);
        const items = await listAll(source, 10);
        fsSync.unlinkSync(filePath);

        await expect(source.deleteItems([items[0].sourceId])).resolves.toBeUndefined();
    });

    test("deleting an item the source has never listed names it in the error", async () => {
        writeFile(path.join(photosDir, "a.jpg"), "one");

        const source = new FolderMediaSource([folderSource(photosDir, true)], 60000, sessionTempDir, uuidGenerator);
        await listAll(source, 10);

        await expect(source.deleteItems(["/somewhere/else.jpg"]))
            .rejects.toThrow(MediaSourceDeleteError);

        let thrown: MediaSourceDeleteError | undefined = undefined;
        try {
            await source.deleteItems(["/somewhere/else.jpg"]);
        }
        catch (error: any) {
            thrown = error;
        }
        expect(thrown!.sourceIds).toEqual(["/somewhere/else.jpg"]);
    });
});
