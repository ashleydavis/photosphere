import {
    addHashFileTiming,
    addDatabaseWriteTiming,
    addDatabaseWriteBreakdown,
    addUploadAssetTiming,
    rankImportStages,
    withExportMs,
    createEmptyImportTimings,
    formatImportTimings,
    hashMegabytesPerSecond,
    hashSharePercent,
    withSkippedBeforeOpening,
    withTotalMs,
    IHashFileTiming,
    IUploadAssetTiming,
    IDatabaseWriteBreakdown,
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
        cacheLoadMs: 0,
        hashFromCache: false,
    };
}

//
// A finished upload-asset task that took the given total time and did nothing else worth timing.
// Stages that matter to a particular test are overridden by the test itself.
//
function uploadedItem(taskMs: number): IUploadAssetTiming {
    return {
        taskMs,
        metadataMs: 0,
        microMs: 0,
        thumbnailMs: 0,
        displayMs: 0,
        uploadMs: 0,
        geocodeMs: 0,
        dominantColorMs: 0,
        otherMs: 0,
        probeMs: 0,
        openStorageMs: 0,
        isVideo: false,
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
        cacheLoadMs: 0,
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
        timings = addUploadAssetTiming(timings, uploadedItem(1_200));

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

    test("an upload's stages each accumulate on their own", () => {
        let timings = addUploadAssetTiming(createEmptyImportTimings(), {
            taskMs: 5_000,
            metadataMs: 100,
            microMs: 200,
            thumbnailMs: 300,
            displayMs: 400,
            uploadMs: 500,
            geocodeMs: 60,
            dominantColorMs: 70,
            otherMs: 0,
            probeMs: 0,
            openStorageMs: 0,
            isVideo: false,
        });
        timings = addUploadAssetTiming(timings, {
            taskMs: 1_000,
            metadataMs: 10,
            microMs: 20,
            thumbnailMs: 30,
            displayMs: 40,
            uploadMs: 50,
            geocodeMs: 6,
            dominantColorMs: 7,
            otherMs: 0,
            probeMs: 0,
            openStorageMs: 0,
            isVideo: true,
        });

        expect(timings.childTaskMs).toBe(6_000);
        expect(timings.metadataMs).toBe(110);
        expect(timings.microMs).toBe(220);
        expect(timings.thumbnailMs).toBe(330);
        expect(timings.displayMs).toBe(440);
        expect(timings.uploadMs).toBe(550);
        expect(timings.geocodeMs).toBe(66);
        expect(timings.dominantColorMs).toBe(77);
        expect(timings.photoMetadataMs).toBe(100);
        expect(timings.videoMetadataMs).toBe(10);
        expect(timings.photosSeen).toBe(1);
        expect(timings.videosSeen).toBe(1);
    });

    test("the export total replaces what was recorded rather than adding to it", () => {
        // The scanner keeps its own running total and reports it on every progress tick, so adding
        // would count every copy again on every tick.
        let timings = withExportMs(createEmptyImportTimings(), 4_000);
        timings = withExportMs(timings, 9_000);

        expect(timings.exportMs).toBe(9_000);
    });

    test("database write time adds up across batches", () => {
        let timings = addDatabaseWriteTiming(createEmptyImportTimings(), 800);
        timings = addDatabaseWriteTiming(timings, 1_200);

        expect(timings.databaseWriteMs).toBe(2_000);
    });

    test("the stages are ranked by what they cost, most expensive first", () => {
        let timings = addUploadAssetTiming(createEmptyImportTimings(), {
            taskMs: 10_000,
            metadataMs: 5_000,
            microMs: 100,
            thumbnailMs: 2_000,
            displayMs: 900,
            uploadMs: 300,
            geocodeMs: 0,
            dominantColorMs: 0,
            otherMs: 0,
            probeMs: 0,
            openStorageMs: 0,
            isVideo: false,
        });
        timings = addHashFileTiming(timings, hashedFile(200, 0, 250, 1_000));

        const ranked = rankImportStages(timings);

        expect(ranked.map(stage => stage.name)).toEqual([
            "photoMetadata",
            "thumbnail",
            "display",
            "upload",
            "hash",
            "micro",
        ]);
        expect(ranked[0].totalMs).toBe(5_000);

        // 5,000 of 8,500 measured milliseconds.
        expect(ranked[0].sharePercent).toBe(58.8);
    });

    test("a stage that cost nothing is left out of the ranking rather than listed at zero", () => {
        const timings = addUploadAssetTiming(createEmptyImportTimings(), {
            taskMs: 1_000,
            metadataMs: 500,
            microMs: 0,
            thumbnailMs: 0,
            displayMs: 0,
            uploadMs: 0,
            geocodeMs: 0,
            dominantColorMs: 0,
            otherMs: 0,
            probeMs: 0,
            openStorageMs: 0,
            isVideo: false,
        });

        expect(rankImportStages(timings).map(stage => stage.name)).toEqual(["photoMetadata"]);
    });

    test("ranking a run that did nothing is empty rather than a division by zero", () => {
        expect(rankImportStages(createEmptyImportTimings())).toEqual([]);
    });

    test("hashing's share is taken against the child task time, not the wall clock", () => {
        let timings = addHashFileTiming(createEmptyImportTimings(), hashedFile(750, 0, 1_000, 1_000_000));
        timings = addUploadAssetTiming(timings, uploadedItem(1_000));

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
        timings = addUploadAssetTiming(timings, uploadedItem(2_000));
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

describe("addDatabaseWriteBreakdown", () => {

    //
    // One batch's breakdown, with every part given a distinct value so a field summed into the wrong
    // total is visible rather than hidden by two numbers that happen to match.
    //
    function batchBreakdown(): IDatabaseWriteBreakdown {
        return {
            flushMs: 1,
            lockWaitMs: 2,
            treeLoadMs: 3,
            addItemsMs: 100,
            merkleAddMs: 40,
            recordInsertMs: 50,
            collectionInsertMs: 44,
            hashCacheAssetIdMs: 6,
            perItemOtherMs: 10,
            treeSaveMs: 4,
            commitMs: 5,
            stampMs: 6,
        };
    }

    test("counts the batch and sums every part of it", () => {
        const timings = addDatabaseWriteBreakdown(createEmptyImportTimings(), batchBreakdown());

        expect(timings.databaseBatches).toBe(1);
        expect(timings.databaseAddItemsMs).toBe(100);
        expect(timings.databaseMerkleAddMs).toBe(40);
        expect(timings.databaseRecordInsertMs).toBe(50);
        expect(timings.databaseCollectionInsertMs).toBe(44);
        expect(timings.databaseHashCacheAssetIdMs).toBe(6);
        expect(timings.databasePerItemOtherMs).toBe(10);
        expect(timings.databaseCommitMs).toBe(5);
    });

    test("accumulates across batches, which is what makes a per-batch cost visible", () => {
        // The whole point of counting batches beside the totals: a cost that grows with the size of
        // the database rather than the size of the batch only shows as a rising cost per batch.
        let timings = addDatabaseWriteBreakdown(createEmptyImportTimings(), batchBreakdown());
        timings = addDatabaseWriteBreakdown(timings, batchBreakdown());

        expect(timings.databaseBatches).toBe(2);
        expect(timings.databaseMerkleAddMs).toBe(80);
        expect(timings.databaseRecordInsertMs).toBe(100);
        expect(timings.databaseCollectionInsertMs).toBe(88);
        expect(timings.databaseHashCacheAssetIdMs).toBe(12);
        expect(timings.databasePerItemOtherMs).toBe(20);
    });
});
