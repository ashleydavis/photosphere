import { IStorage } from "storage";
import { IMPORT_RECORD_PATH, MAX_IMPORT_RECORD_ENTRIES, IImportRecordEntry } from "api/src/lib/import-record";
import { loadImportRecord, recordImports } from "../../lib/import-record-storage";

//
// A storage that keeps one file in memory, so the record can be read and written without a disk.
//
function makeStorage(initial?: string) {
    let contents: string | undefined = initial;
    const writes: string[] = [];

    const storage = {
        read: async (path: string) => {
            if (path !== IMPORT_RECORD_PATH || contents === undefined) {
                return undefined;
            }
            return Buffer.from(contents, "utf8");
        },
        write: async (path: string, _contentType: string, data: Buffer) => {
            writes.push(path);
            contents = data.toString("utf8");
        },
    } as unknown as IStorage;

    return {
        storage,
        writes,
        current: () => contents,
    };
}

//
// One import, with everything filled in.
//
function makeEntry(logicalPath: string, source: "manual" | "automatic" = "manual"): IImportRecordEntry {
    return {
        assetId: `asset-${logicalPath}`,
        logicalPath,
        outcome: "imported",
        importedAt: "2026-01-01T00:00:00.000Z",
        source,
    };
}

describe("the stored import record", () => {

    test("a database that has imported nothing reads as empty", async () => {
        const { storage } = makeStorage();

        const record = await loadImportRecord(storage);

        expect(record.entries).toEqual([]);
        expect(record.truncated).toBe(false);
    });

    test("what was recorded is what comes back", async () => {
        const { storage } = makeStorage();

        await recordImports(storage, [makeEntry("one"), makeEntry("two", "automatic")]);

        const record = await loadImportRecord(storage);
        expect(record.entries.map(entry => entry.logicalPath)).toEqual(["two", "one"]);
        expect(record.entries.map(entry => entry.source)).toEqual(["automatic", "manual"]);
    });

    test("a later import is added to what was already there", async () => {
        const { storage } = makeStorage();

        await recordImports(storage, [makeEntry("one")]);
        await recordImports(storage, [makeEntry("two")]);

        const record = await loadImportRecord(storage);
        expect(record.entries.map(entry => entry.logicalPath)).toEqual(["two", "one"]);
    });

    test("recording nothing does not write", async () => {
        const { storage, writes } = makeStorage();

        await recordImports(storage, []);

        expect(writes).toEqual([]);
    });

    test("it is written to .db/imports.dat and nowhere else", async () => {
        const { storage, writes } = makeStorage();

        await recordImports(storage, [makeEntry("one")]);

        // The path matters: it is deliberately not in the merkle tree, which is what keeps it out of
        // sync and replication.
        expect(writes).toEqual([IMPORT_RECORD_PATH]);
    });

    test("an unreadable record reads as empty rather than throwing", async () => {
        const { storage } = makeStorage("this is not a record");

        const record = await loadImportRecord(storage);

        expect(record.entries).toEqual([]);
    });

    test("storage that cannot be read reads as empty rather than throwing", async () => {
        const storage = {
            read: async () => { throw new Error("the disk is on fire"); },
            write: async () => { /* never reached. */ },
        } as unknown as IStorage;

        // This is a note about what happened, not the photos. It is not worth refusing to open a
        // database over.
        await expect(loadImportRecord(storage)).resolves.toEqual({ entries: [], truncated: false });
    });

    test("a record that cannot be written does not fail the import", async () => {
        const storage = {
            read: async () => undefined,
            write: async () => { throw new Error("the disk is full"); },
        } as unknown as IStorage;

        // The photos are already in the database by this point. Losing the note about them must not
        // turn a successful import into a failed one.
        await expect(recordImports(storage, [makeEntry("one")])).resolves.toBeUndefined();
    });

    test("the record stays capped across many imports", async () => {
        const { storage } = makeStorage();

        for (let batch = 0; batch < 3; batch += 1) {
            const entries = Array.from({ length: 400 }, (_unused, index) => makeEntry(`batch-${batch}-file-${index}`));
            await recordImports(storage, entries);
        }

        const record = await loadImportRecord(storage);
        expect(record.entries).toHaveLength(MAX_IMPORT_RECORD_ENTRIES);
        expect(record.truncated).toBe(true);
        // The newest survived, which is the half of the cap that matters.
        expect(record.entries[0].logicalPath).toBe("batch-2-file-399");
    });
});
