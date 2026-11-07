import { DEFAULT_AUTO_IMPORT_SETTINGS } from "api/src/lib/auto-import-settings";
import { buildCleanupSourcesTaskData, describeCleanupResult, ICleanupSourcesTaskResult } from "../../lib/source-cleanup-request";

//
// A cleanup result with the given counts.
//
function makeResult(overrides: Partial<ICleanupSourcesTaskResult>): ICleanupSourcesTaskResult {
    return {
        considered: 0,
        deletableSourceIds: [],
        deletedSourceIds: [],
        failedSourceIds: [],
        ...overrides,
    };
}

describe("buildCleanupSourcesTaskData", () => {

    test("names the database to check against", () => {
        const data = buildCleanupSourcesTaskData("/photos/db", DEFAULT_AUTO_IMPORT_SETTINGS, true);

        expect(data.storageDescriptor.databasePath).toBe("/photos/db");
    });

    test("carries the places to look, which are the ones automatic import watches", () => {
        const settings = { ...DEFAULT_AUTO_IMPORT_SETTINGS, sources: [{ type: "folder" as const, path: "/photos", recurse: true }] };

        const data = buildCleanupSourcesTaskData("/photos/db", settings, true);

        expect(data.settings.sources).toEqual([{ type: "folder", path: "/photos", recurse: true }]);
    });

    test("asks for a counting pass or a deleting one, as it was told", () => {
        expect(buildCleanupSourcesTaskData("/photos/db", DEFAULT_AUTO_IMPORT_SETTINGS, true).dryRun).toBe(true);
        expect(buildCleanupSourcesTaskData("/photos/db", DEFAULT_AUTO_IMPORT_SETTINGS, false).dryRun).toBe(false);
    });
});

describe("describeCleanupResult", () => {

    test("says nothing at all when nothing has run", () => {
        expect(describeCleanupResult(undefined, true)).toBe("");
    });

    test("a counting pass that found photos says how many, out of how many", () => {
        const message = describeCleanupResult(makeResult({ considered: 100, deletableSourceIds: ["a", "b"] }), true);

        expect(message).toContain("2");
        expect(message).toContain("100");
    });

    test("a counting pass that found nothing says why, rather than looking like it did nothing", () => {
        // "Nothing happened" and "there was nothing to do" are the same thing on screen otherwise.
        const message = describeCleanupResult(makeResult({ considered: 100 }), true);

        expect(message).toContain("Nothing to delete");
        expect(message).toContain("100");
    });

    test("a deleting pass says how many went", () => {
        const message = describeCleanupResult(makeResult({ deletedSourceIds: ["a", "b", "c"] }), false);

        expect(message).toContain("Deleted 3");
    });

    test("a deleting pass says what would not go, rather than reporting a clean run", () => {
        const message = describeCleanupResult(makeResult({ deletedSourceIds: ["a"], failedSourceIds: ["b", "c"] }), false);

        expect(message).toContain("Deleted 1");
        expect(message).toContain("2 could not be deleted");
    });
});
