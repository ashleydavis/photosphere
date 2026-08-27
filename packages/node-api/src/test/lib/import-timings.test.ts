import {
    addHashFileTiming,
    addUploadAssetTiming,
    createEmptyImportTimings,
    formatImportTimings,
    hashMegabytesPerSecond,
    hashSharePercent,
    withSkippedBeforeOpening,
    withTotalMs,
    IHashFileTiming,
} from "../../lib/import-timings";

//
// A finished hash-file task that hashed a file, with the timings and size given.
//
function hashedFile(hashMs: number, cacheLookupMs: number, taskMs: number, bytesHashed: number): IHashFileTiming {
    return {
        hashMs,
        cacheLookupMs,
        taskMs,
        bytesHashed,
        hashFromCache: false,
    };
}

//
// A finished hash-file task that the hash cache answered for, so nothing was hashed.
//
function cachedFile(cacheLookupMs: number, taskMs: number): IHashFileTiming {
    return {
        hashMs: 0,
        cacheLookupMs,
        taskMs,
        bytesHashed: 0,
        hashFromCache: true,
    };
}

describe("import timings", () => {

    test("a run that has done nothing has nothing in it", () => {
        const timings = createEmptyImportTimings();
        expect(timings.totalMs).toBe(0);
        expect(timings.hashMs).toBe(0);
        expect(timings.cacheLookupMs).toBe(0);
        expect(timings.childTaskMs).toBe(0);
        expect(timings.filesHashed).toBe(0);
        expect(timings.filesFromCache).toBe(0);
        expect(timings.bytesHashed).toBe(0);
    });

    test("a hashed file adds its hashing time, its bytes and one to the hashed count", () => {
        const timings = addHashFileTiming(createEmptyImportTimings(), hashedFile(500, 3, 540, 2_000_000));
        expect(timings.hashMs).toBe(500);
        expect(timings.cacheLookupMs).toBe(3);
        expect(timings.childTaskMs).toBe(540);
        expect(timings.filesHashed).toBe(1);
        expect(timings.filesFromCache).toBe(0);
        expect(timings.bytesHashed).toBe(2_000_000);
    });

    test("a cached file adds no hashing time and no bytes, and counts as cached", () => {
        const timings = addHashFileTiming(createEmptyImportTimings(), cachedFile(2, 4));
        expect(timings.hashMs).toBe(0);
        expect(timings.cacheLookupMs).toBe(2);
        expect(timings.childTaskMs).toBe(4);
        expect(timings.filesHashed).toBe(0);
        expect(timings.filesFromCache).toBe(1);
        expect(timings.bytesHashed).toBe(0);
    });

    test("hashed and cached files accumulate together", () => {
        let timings = createEmptyImportTimings();
        timings = addHashFileTiming(timings, hashedFile(500, 3, 540, 2_000_000));
        timings = addHashFileTiming(timings, hashedFile(300, 2, 330, 1_000_000));
        timings = addHashFileTiming(timings, cachedFile(1, 5));

        expect(timings.hashMs).toBe(800);
        expect(timings.cacheLookupMs).toBe(6);
        expect(timings.childTaskMs).toBe(875);
        expect(timings.filesHashed).toBe(2);
        expect(timings.filesFromCache).toBe(1);
        expect(timings.bytesHashed).toBe(3_000_000);
    });

    test("an upload adds only to the child task total", () => {
        let timings = addHashFileTiming(createEmptyImportTimings(), hashedFile(500, 3, 540, 2_000_000));
        timings = addUploadAssetTiming(timings, 1_200);

        expect(timings.childTaskMs).toBe(1_740);
        expect(timings.hashMs).toBe(500);
        expect(timings.filesHashed).toBe(1);
        expect(timings.bytesHashed).toBe(2_000_000);
    });

    test("folding in a task leaves the timings it was given untouched", () => {
        const before = addHashFileTiming(createEmptyImportTimings(), hashedFile(500, 3, 540, 2_000_000));
        const after = addHashFileTiming(before, hashedFile(100, 1, 110, 500_000));

        expect(before.hashMs).toBe(500);
        expect(before.filesHashed).toBe(1);
        expect(after.hashMs).toBe(600);
        expect(after.filesHashed).toBe(2);
    });

    test("the run's wall clock is stamped on without disturbing the rest", () => {
        const accumulated = addHashFileTiming(createEmptyImportTimings(), hashedFile(500, 3, 540, 2_000_000));
        const stamped = withTotalMs(accumulated, 9_000);

        expect(stamped.totalMs).toBe(9_000);
        expect(stamped.hashMs).toBe(500);
        expect(stamped.childTaskMs).toBe(540);
        expect(accumulated.totalMs).toBe(0);
    });

    test("a warm run reports the items the scanner recognised without opening them", () => {
        // This is the whole of a warm run: nothing is hashed, nothing is opened, and every other
        // counter stays at zero. Without this field such a run reports doing nothing at all.
        const timings = withTotalMs(withSkippedBeforeOpening(createEmptyImportTimings(), 2_186), 900);

        expect(timings.skippedBeforeOpening).toBe(2_186);
        expect(timings.filesHashed).toBe(0);
        expect(timings.bytesHashed).toBe(0);
        expect(timings.totalMs).toBe(900);
    });

    test("recording the scanner's skips leaves everything else alone", () => {
        const accumulated = addHashFileTiming(createEmptyImportTimings(), hashedFile(500, 3, 540, 2_000_000));
        const recorded = withSkippedBeforeOpening(accumulated, 7);

        expect(recorded.skippedBeforeOpening).toBe(7);
        expect(recorded.hashMs).toBe(500);
        expect(recorded.filesHashed).toBe(1);
        expect(accumulated.skippedBeforeOpening).toBe(0);
    });

    test("hashing's share is taken against the child task time, not the wall clock", () => {
        let timings = addHashFileTiming(createEmptyImportTimings(), hashedFile(750, 0, 1_000, 1_000_000));
        timings = addUploadAssetTiming(timings, 1_000);

        // 750 of 2,000 milliseconds of child task time. The wall clock is deliberately set to
        // something the answer must ignore: tasks run concurrently, so a share of the wall clock
        // would report a number that changes with how many run at once.
        timings = withTotalMs(timings, 1_100);
        expect(hashSharePercent(timings)).toBe(37.5);
    });

    test("hashing's share is zero rather than a division by zero when nothing ran", () => {
        expect(hashSharePercent(createEmptyImportTimings())).toBe(0);
    });

    test("the hashing rate is reported in megabytes per second", () => {
        // Ten mebibytes in two seconds is five mebibytes a second.
        const timings = addHashFileTiming(createEmptyImportTimings(), hashedFile(2_000, 0, 2_100, 10 * 1024 * 1024));
        expect(hashMegabytesPerSecond(timings)).toBe(5);
    });

    test("the hashing rate is zero rather than a division by zero when nothing was hashed", () => {
        const timings = addHashFileTiming(createEmptyImportTimings(), cachedFile(1, 2));
        expect(hashMegabytesPerSecond(timings)).toBe(0);
    });

    test("the summary line carries every figure a comparison needs, as readable JSON", () => {
        let timings = addHashFileTiming(createEmptyImportTimings(), hashedFile(2_000, 5, 2_100, 10 * 1024 * 1024));
        timings = addHashFileTiming(timings, cachedFile(1, 3));
        timings = addUploadAssetTiming(timings, 2_000);
        timings = withTotalMs(timings, 5_000);

        const line = formatImportTimings(timings);
        expect(line.startsWith("Import timings: ")).toBe(true);

        const summary = JSON.parse(line.substring("Import timings: ".length));
        expect(summary.totalMs).toBe(5_000);
        expect(summary.childTaskMs).toBe(4_103);
        expect(summary.hashMs).toBe(2_000);
        expect(summary.cacheLookupMs).toBe(6);
        expect(summary.filesHashed).toBe(1);
        expect(summary.filesFromCache).toBe(1);
        expect(summary.skippedBeforeOpening).toBe(0);
        expect(summary.bytesHashed).toBe(10 * 1024 * 1024);
        expect(summary.hashMbPerSecond).toBe(5);
    });
});
