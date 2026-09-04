import * as fs from "fs/promises";
import * as path from "path";
import { createTestTempDir } from "node-utils";
import { MAX_IMPORT_RECORD_ENTRIES, IImportRecordEntry } from "api/src/lib/import-record";
import { getImportRecordPath } from "../../lib/database-cache-dir";
import { loadImportRecord, recordImports } from "../../lib/import-record-storage";

//
// Puts the cache directory back the way it was, so a test that pointed it somewhere of its own does
// not leave that setting for whatever runs next.
//
function restoreEnvironmentVariable(name: string, originalValue: string | undefined): void {
    if (originalValue === undefined) {
        delete process.env[name];
    }
    else {
        process.env[name] = originalValue;
    }
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

describe("this machine's import record", () => {
    //
    // Every test points the cache directory at one of its own, so the record is written to a real
    // filesystem without any of them reaching the developer's real record or each other's.
    //
    let originalCacheDir: string | undefined;
    let databasePath: string;

    beforeEach(() => {
        originalCacheDir = process.env.PHOTOSPHERE_CACHE_DIR;
        const runRoot = createTestTempDir("import-record-test");
        process.env.PHOTOSPHERE_CACHE_DIR = path.join(runRoot, "cache");
        databasePath = path.join(runRoot, "photos");
    });

    afterEach(() => {
        restoreEnvironmentVariable("PHOTOSPHERE_CACHE_DIR", originalCacheDir);
    });

    test("a database that has imported nothing reads as empty", async () => {
        const record = await loadImportRecord(databasePath);

        expect(record.entries).toEqual([]);
        expect(record.truncated).toBe(false);
    });

    test("what was recorded is what comes back", async () => {
        await recordImports(databasePath, [makeEntry("one"), makeEntry("two", "automatic")]);

        const record = await loadImportRecord(databasePath);
        expect(record.entries.map(entry => entry.logicalPath)).toEqual(["two", "one"]);
        expect(record.entries.map(entry => entry.source)).toEqual(["automatic", "manual"]);
    });

    test("a later import is added to what was already there", async () => {
        await recordImports(databasePath, [makeEntry("one")]);
        await recordImports(databasePath, [makeEntry("two")]);

        const record = await loadImportRecord(databasePath);
        expect(record.entries.map(entry => entry.logicalPath)).toEqual(["two", "one"]);
    });

    test("it is written to the local path and nowhere else", async () => {
        await recordImports(databasePath, [makeEntry("one")]);

        // The location is the whole point of this file: a local path derived from the database path,
        // not a path inside the database, so nothing that copies the database can carry it.
        const written = await fs.readFile(getImportRecordPath(databasePath), "utf8");
        expect(JSON.parse(written).entries[0].logicalPath).toBe("one");
    });

    test("the record is created outside the database, which is left untouched", async () => {
        await fs.mkdir(databasePath, { recursive: true });

        await recordImports(databasePath, [makeEntry("one")]);

        // Nothing may appear inside the database. Being outside it is what stops the record
        // travelling by sync, replication or consolidation.
        expect(await fs.readdir(databasePath)).toEqual([]);
        expect(getImportRecordPath(databasePath).startsWith(databasePath)).toBe(false);
    });

    test("the cache directory is made when it is not there yet", async () => {
        // Nothing creates this directory ahead of the first import, so the first write has to.
        const recordDir = path.dirname(getImportRecordPath(databasePath));
        await expect(fs.stat(recordDir)).rejects.toThrow();

        await recordImports(databasePath, [makeEntry("one")]);

        expect((await fs.stat(recordDir)).isDirectory()).toBe(true);
    });

    test("recording nothing does not write", async () => {
        await recordImports(databasePath, []);

        await expect(fs.stat(getImportRecordPath(databasePath))).rejects.toThrow();
    });

    test("a record that is not JSON reads as empty rather than throwing", async () => {
        const recordPath = getImportRecordPath(databasePath);
        await fs.mkdir(path.dirname(recordPath), { recursive: true });
        await fs.writeFile(recordPath, "this is not a record");

        const record = await loadImportRecord(databasePath);

        expect(record.entries).toEqual([]);
    });

    test("JSON that is not a record reads as empty rather than throwing", async () => {
        const recordPath = getImportRecordPath(databasePath);
        await fs.mkdir(path.dirname(recordPath), { recursive: true });
        await fs.writeFile(recordPath, JSON.stringify({ somethingElse: true }));

        const record = await loadImportRecord(databasePath);

        expect(record.entries).toEqual([]);
    });

    test("a record that cannot be read reads as empty rather than throwing", async () => {
        // A directory where the file should be: reading it fails the way an unreadable file does.
        // This is a note about what happened, not the photos. It is not worth refusing to open a
        // database over.
        await fs.mkdir(getImportRecordPath(databasePath), { recursive: true });

        await expect(loadImportRecord(databasePath)).resolves.toEqual({ entries: [], truncated: false });
    });

    test("a record that cannot be written does not fail the import", async () => {
        // The cache root is a file, so the directory the record needs cannot be created.
        const blockedRoot = path.join(createTestTempDir("import-record-blocked"), "cache");
        await fs.writeFile(blockedRoot, "not a directory");
        process.env.PHOTOSPHERE_CACHE_DIR = blockedRoot;

        // The photos are already in the database by this point. Losing the note about them must not
        // turn a successful import into a failed one.
        await expect(recordImports(databasePath, [makeEntry("one")])).resolves.toBeUndefined();
    });

    test("the record stays capped across many imports", async () => {
        for (let batch = 0; batch < 3; batch += 1) {
            const entries = Array.from({ length: 400 }, (_unused, index) => makeEntry(`batch-${batch}-file-${index}`));
            await recordImports(databasePath, entries);
        }

        const record = await loadImportRecord(databasePath);
        expect(record.entries).toHaveLength(MAX_IMPORT_RECORD_ENTRIES);
        expect(record.truncated).toBe(true);
        // The newest survived, which is the half of the cap that matters.
        expect(record.entries[0].logicalPath).toBe("batch-2-file-399");
    });

    test("writers into one database at the same time all survive", async () => {
        // The CLI and the desktop app can import into the same database at once. A plain
        // read-modify-write loses all but the last of these, because each reads the same record
        // before any of them has written.
        const writerCount = 8;
        await Promise.all(
            Array.from({ length: writerCount }, (_unused, index) =>
                recordImports(databasePath, [makeEntry(`writer-${index}`)])
            )
        );

        const record = await loadImportRecord(databasePath);
        const recorded = record.entries.map(entry => entry.logicalPath).sort();
        expect(recorded).toEqual(
            Array.from({ length: writerCount }, (_unused, index) => `writer-${index}`).sort()
        );
    });
});
