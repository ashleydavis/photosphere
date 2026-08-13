import {
    IImportRecordEntry,
    MAX_IMPORT_RECORD_ENTRIES,
    addImportEntries,
    createImportRecord,
    parseImportRecord,
    serializeImportRecord,
} from "../../lib/import-record";

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
        micro: "abc",
    };
}

describe("the import record", () => {

    test("a new record has nothing in it and nothing dropped", () => {
        const record = createImportRecord();

        expect(record.entries).toEqual([]);
        expect(record.truncated).toBe(false);
    });

    test("imports are kept newest first", () => {
        // They arrive oldest first, in the order they happened, and are shown the other way round.
        const record = addImportEntries(createImportRecord(), [makeEntry("one"), makeEntry("two")]);

        expect(record.entries.map(entry => entry.logicalPath)).toEqual(["two", "one"]);
    });

    test("a later import goes above an earlier one", () => {
        const first = addImportEntries(createImportRecord(), [makeEntry("one")]);
        const second = addImportEntries(first, [makeEntry("two")]);

        expect(second.entries.map(entry => entry.logicalPath)).toEqual(["two", "one"]);
    });

    test("manual and automatic imports go into the same list", () => {
        const record = addImportEntries(createImportRecord(), [
            makeEntry("asked-for", "manual"),
            makeEntry("arrived", "automatic"),
        ]);

        expect(record.entries.map(entry => entry.source)).toEqual(["automatic", "manual"]);
    });

    test("adding nothing leaves the record alone", () => {
        const before = addImportEntries(createImportRecord(), [makeEntry("one")]);
        const after = addImportEntries(before, []);

        expect(after).toBe(before);
    });

    test("nothing is dropped until the cap is reached", () => {
        const entries = Array.from({ length: MAX_IMPORT_RECORD_ENTRIES }, (_unused, index) => makeEntry(`file-${index}`));

        const record = addImportEntries(createImportRecord(), entries);

        expect(record.entries).toHaveLength(MAX_IMPORT_RECORD_ENTRIES);
        expect(record.truncated).toBe(false);
    });

    test("past the cap the oldest go, and the record says so", () => {
        const entries = Array.from({ length: MAX_IMPORT_RECORD_ENTRIES + 1 }, (_unused, index) => makeEntry(`file-${index}`));

        const record = addImportEntries(createImportRecord(), entries);

        expect(record.entries).toHaveLength(MAX_IMPORT_RECORD_ENTRIES);
        // The newest survives and the oldest is the one that went.
        expect(record.entries[0].logicalPath).toBe(`file-${MAX_IMPORT_RECORD_ENTRIES}`);
        expect(record.entries.some(entry => entry.logicalPath === "file-0")).toBe(false);
        // Saying so matters: a list that silently stops is read as the whole history.
        expect(record.truncated).toBe(true);
    });

    test("once something has been dropped the record stays truncated", () => {
        const full = addImportEntries(
            createImportRecord(),
            Array.from({ length: MAX_IMPORT_RECORD_ENTRIES + 1 }, (_unused, index) => makeEntry(`file-${index}`))
        );

        const later = addImportEntries(full, [makeEntry("newest")]);

        // The hole in the history does not heal by adding more.
        expect(later.truncated).toBe(true);
    });

    test("adding does not change the record it was given", () => {
        const before = addImportEntries(createImportRecord(), [makeEntry("one")]);

        addImportEntries(before, [makeEntry("two")]);

        expect(before.entries.map(entry => entry.logicalPath)).toEqual(["one"]);
    });

    test("a record survives being written and read back", () => {
        const record = addImportEntries(createImportRecord(), [makeEntry("one"), makeEntry("two", "automatic")]);

        const readBack = parseImportRecord(serializeImportRecord(record));

        expect(readBack).toEqual(record);
    });

    test("a file that is not a record reads as empty rather than throwing", () => {
        expect(parseImportRecord("not json at all").entries).toEqual([]);
        expect(parseImportRecord("[]").entries).toEqual([]);
        expect(parseImportRecord("null").entries).toEqual([]);
        expect(parseImportRecord("{}").entries).toEqual([]);
    });

    test("entries that are not imports are dropped rather than shown", () => {
        const contents = JSON.stringify({
            entries: [
                makeEntry("good"),
                { logicalPath: "no outcome", source: "manual" },
                { outcome: "imported", source: "manual" },
                { logicalPath: "bad source", outcome: "imported", source: "somewhere" },
                null,
                "not an object",
            ],
            truncated: false,
        });

        const record = parseImportRecord(contents);

        expect(record.entries.map(entry => entry.logicalPath)).toEqual(["good"]);
    });

    test("a stored record longer than the cap is trimmed and marked truncated", () => {
        const contents = JSON.stringify({
            entries: Array.from({ length: MAX_IMPORT_RECORD_ENTRIES + 5 }, (_unused, index) => makeEntry(`file-${index}`)),
            truncated: false,
        });

        const record = parseImportRecord(contents);

        expect(record.entries).toHaveLength(MAX_IMPORT_RECORD_ENTRIES);
        expect(record.truncated).toBe(true);
    });
});
