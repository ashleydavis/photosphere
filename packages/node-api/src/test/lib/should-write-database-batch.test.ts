import { DATABASE_BATCH_SIZE, shouldWriteDatabaseBatch } from "../../lib/import-assets.worker";

//
// Covers when the import writes what it is holding into the database. Every write pays for a full
// database commit whatever its size, so writing too eagerly is what makes a long import crawl.
//
describe("shouldWriteDatabaseBatch", () => {

    test("nothing waiting is nothing to write", () => {
        expect(shouldWriteDatabaseBatch(0, true, false)).toBe(false);
    });

    test("a full batch is written", () => {
        expect(shouldWriteDatabaseBatch(DATABASE_BATCH_SIZE, false, true)).toBe(true);
    });

    test("more than a full batch is written", () => {
        expect(shouldWriteDatabaseBatch(DATABASE_BATCH_SIZE + 1, false, true)).toBe(true);
    });

    test("a part-filled batch waits while the scanner still has photos to hand over", () => {
        expect(shouldWriteDatabaseBatch(1, false, false)).toBe(false);
    });

    test("a part-filled batch waits while photos already handed over are still being worked on", () => {
        // This is the backfill: the scanner reaches the end of the library long before the import
        // finishes with the photos it pushed. Writing here gives each of those a commit of its own.
        expect(shouldWriteDatabaseBatch(1, true, true)).toBe(false);
    });

    test("a part-filled batch is written once the scanner is caught up and nothing is in flight", () => {
        // An automatic import that took in a few photos and went quiet: those few have to be written
        // rather than held for a batch that may be hours away.
        expect(shouldWriteDatabaseBatch(1, true, false)).toBe(true);
    });
});
