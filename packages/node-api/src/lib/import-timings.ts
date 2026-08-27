import { IImportTimings } from "api/src/lib/import-assets.types";

//
// Accounting for where an import run's time went.
//
// Kept apart from the import task itself so it can be tested without running an import. The task
// gathers the numbers; everything that decides what they mean lives here.
//
// The one thing to understand before reading a figure out of this: an import runs several child
// tasks at once, so the per-task milliseconds summed here add up to more than the run's wall clock.
// Hashing is therefore a share of `childTaskMs`, never of `totalMs`. Dividing by the wall clock
// would report a number that quietly depends on how many tasks the device runs in parallel, which is
// exactly the sort of figure that looks like a measurement and is not.
//
// Every function here copies what it was given and overrides what it changes, rather than listing
// every field. A stage added to IImportTimings then reaches all of them, instead of being silently
// dropped by whichever one was not updated.
//

//
// The timing fields an import reads off a finished hash-file task. `IHashFileResult` satisfies this,
// which is why the task's own result type is not imported here: this module has no reason to know
// what else a hash-file task reports.
//
export interface IHashFileTiming {
    // How long the hashing itself took, zero when the cache answered.
    hashMs: number;

    // How long asking the hash cache took, whether it answered or not.
    cacheLookupMs: number;

    // How long the whole task took.
    taskMs: number;

    // How many bytes were hashed, zero when the cache answered.
    bytesHashed: number;

    // How long loading the hash cache took.
    cacheLoadMs: number;

    // Whether the cache answered, so no hashing was needed.
    hashFromCache: boolean;
}

//
// The per-stage timings an import reads off a finished upload-asset task. `IUploadAssetResult`
// satisfies this.
//
export interface IUploadAssetTiming {
    // How long the whole task took.
    taskMs: number;

    // How long reading the item's own metadata took: the EXIF block on a photo, the probe on a video.
    metadataMs: number;

    // How long each of the three derivative images took to produce.
    microMs: number;
    thumbnailMs: number;
    displayMs: number;

    // How long writing the original and its derivatives into storage took.
    uploadMs: number;

    // How long reverse geocoding took, zero when the item carried no coordinates.
    geocodeMs: number;

    // How long working out the dominant colour took.
    dominantColorMs: number;

    // Opening storage, once per task.
    openStorageMs: number;

    // What the task spent on things none of the other counters name, and the media tool probe.
    otherMs: number;
    probeMs: number;

    // Whether this item was a video rather than a photo.
    isVideo: boolean;
}

//
// A run's timings before it has done anything.
//
export function createEmptyImportTimings(): IImportTimings {
    return {
        totalMs: 0,
        hashMs: 0,
        cacheLookupMs: 0,
        cacheLoadMs: 0,
        childTaskMs: 0,
        filesHashed: 0,
        filesFromCache: 0,
        skippedBeforeOpening: 0,
        bytesHashed: 0,
        exportMs: 0,
        metadataMs: 0,
        photoMetadataMs: 0,
        videoMetadataMs: 0,
        microMs: 0,
        thumbnailMs: 0,
        displayMs: 0,
        uploadMs: 0,
        geocodeMs: 0,
        dominantColorMs: 0,
        otherMs: 0,
        probeMs: 0,
        openStorageMs: 0,
        databaseWriteMs: 0,
        databaseBatches: 0,
        databaseFlushMs: 0,
        databaseLockWaitMs: 0,
        databaseTreeLoadMs: 0,
        databaseAddItemsMs: 0,
        databaseMerkleAddMs: 0,
        databaseRecordInsertMs: 0,
        databaseCollectionInsertMs: 0,
        databaseHashCacheAssetIdMs: 0,
        databasePerItemOtherMs: 0,
        databaseTreeSaveMs: 0,
        databaseCommitMs: 0,
        databaseStampMs: 0,
        photosSeen: 0,
        videosSeen: 0,
    };
}

//
// Folds one finished hash-file task into a run's timings, returning the new totals.
//
// Returns fresh totals rather than changing the ones it was given: the import calls this from a task
// completion callback, and totals that are replaced whole cannot be read half-updated by whatever
// else is running at that moment.
//
export function addHashFileTiming(timings: IImportTimings, hashFileTiming: IHashFileTiming): IImportTimings {
    return {
        ...timings,
        hashMs: timings.hashMs + hashFileTiming.hashMs,
        cacheLookupMs: timings.cacheLookupMs + hashFileTiming.cacheLookupMs,
        cacheLoadMs: timings.cacheLoadMs + hashFileTiming.cacheLoadMs,
        childTaskMs: timings.childTaskMs + hashFileTiming.taskMs,
        filesHashed: timings.filesHashed + (hashFileTiming.hashFromCache ? 0 : 1),
        filesFromCache: timings.filesFromCache + (hashFileTiming.hashFromCache ? 1 : 0),
        bytesHashed: timings.bytesHashed + hashFileTiming.bytesHashed,
    };
}

//
// Folds one finished upload-asset task into a run's timings: its own time, and each stage inside it.
//
export function addUploadAssetTiming(timings: IImportTimings, uploadTiming: IUploadAssetTiming): IImportTimings {
    return {
        ...timings,
        childTaskMs: timings.childTaskMs + uploadTiming.taskMs,
        metadataMs: timings.metadataMs + uploadTiming.metadataMs,
        photoMetadataMs: timings.photoMetadataMs + (uploadTiming.isVideo ? 0 : uploadTiming.metadataMs),
        videoMetadataMs: timings.videoMetadataMs + (uploadTiming.isVideo ? uploadTiming.metadataMs : 0),
        microMs: timings.microMs + uploadTiming.microMs,
        thumbnailMs: timings.thumbnailMs + uploadTiming.thumbnailMs,
        displayMs: timings.displayMs + uploadTiming.displayMs,
        uploadMs: timings.uploadMs + uploadTiming.uploadMs,
        geocodeMs: timings.geocodeMs + uploadTiming.geocodeMs,
        dominantColorMs: timings.dominantColorMs + uploadTiming.dominantColorMs,
        otherMs: timings.otherMs + uploadTiming.otherMs,
        probeMs: timings.probeMs + uploadTiming.probeMs,
        openStorageMs: timings.openStorageMs + uploadTiming.openStorageMs,
        photosSeen: timings.photosSeen + (uploadTiming.isVideo ? 0 : 1),
        videosSeen: timings.videosSeen + (uploadTiming.isVideo ? 1 : 0),
    };
}

//
// Records the total time spent copying items out of the source.
//
// The scanner keeps this as a running total of its own, so this replaces what was recorded rather
// than adding to it. Adding would count every copy again on every progress report.
//
export function withExportMs(timings: IImportTimings, exportMs: number): IImportTimings {
    return {
        ...timings,
        exportMs,
    };
}

//
// Adds the time one batch of finished assets took to write to the database.
//
export function addDatabaseWriteTiming(timings: IImportTimings, databaseWriteMs: number): IImportTimings {
    return {
        ...timings,
        databaseWriteMs: timings.databaseWriteMs + databaseWriteMs,
    };
}

//
// What one batch of database writes was spent on.
//
export interface IDatabaseWriteBreakdown {
    // Flushing whatever the database was holding before the lock is taken.
    flushMs: number;

    // Waiting for the write lock.
    lockWaitMs: number;

    // Loading the whole merkle tree.
    treeLoadMs: number;

    // Adding this batch.'s items to the tree and inserting their records.
    addItemsMs: number;

    // That loop split three ways, because it is the largest part of a database write and its cost
    // grows with the size of the database rather than with the size of the batch: adding the items
    // to the merkle tree, inserting the records with their sort indexes, and everything else the
    // loop does per item.
    merkleAddMs: number;
    recordInsertMs: number;

    // That insert split again: putting the record in the collection, and writing the asset id into
    // the hash cache entry for the file it came from.
    collectionInsertMs: number;
    hashCacheAssetIdMs: number;
    perItemOtherMs: number;

    // Saving the whole merkle tree back.
    treeSaveMs: number;

    // Committing the database.
    commitMs: number;

    // Stamping the database as modified.
    stampMs: number;
}

//
// Folds one batch's breakdown in, and counts the batch.
//
export function addDatabaseWriteBreakdown(timings: IImportTimings, breakdown: IDatabaseWriteBreakdown): IImportTimings {
    return {
        ...timings,
        databaseBatches: timings.databaseBatches + 1,
        databaseFlushMs: timings.databaseFlushMs + breakdown.flushMs,
        databaseLockWaitMs: timings.databaseLockWaitMs + breakdown.lockWaitMs,
        databaseTreeLoadMs: timings.databaseTreeLoadMs + breakdown.treeLoadMs,
        databaseAddItemsMs: timings.databaseAddItemsMs + breakdown.addItemsMs,
        databaseMerkleAddMs: timings.databaseMerkleAddMs + breakdown.merkleAddMs,
        databaseRecordInsertMs: timings.databaseRecordInsertMs + breakdown.recordInsertMs,
        databaseCollectionInsertMs: timings.databaseCollectionInsertMs + breakdown.collectionInsertMs,
        databaseHashCacheAssetIdMs: timings.databaseHashCacheAssetIdMs + breakdown.hashCacheAssetIdMs,
        databasePerItemOtherMs: timings.databasePerItemOtherMs + breakdown.perItemOtherMs,
        databaseTreeSaveMs: timings.databaseTreeSaveMs + breakdown.treeSaveMs,
        databaseCommitMs: timings.databaseCommitMs + breakdown.commitMs,
        databaseStampMs: timings.databaseStampMs + breakdown.stampMs,
    };
}

//
// Stamps the run's wall clock onto its timings, once the run has finished.
//
export function withTotalMs(timings: IImportTimings, totalMs: number): IImportTimings {
    return {
        ...timings,
        totalMs,
    };
}

//
// Records how many items the scanner recognised without opening them, which is a count the scanner
// keeps rather than something the child tasks report.
//
export function withSkippedBeforeOpening(timings: IImportTimings, skippedBeforeOpening: number): IImportTimings {
    return {
        ...timings,
        skippedBeforeOpening,
    };
}

//
// Hashing as a percentage of the time the child tasks spent, to one decimal place. Zero when nothing
// ran, rather than a division by zero.
//
export function hashSharePercent(timings: IImportTimings): number {
    if (timings.childTaskMs === 0) {
        return 0;
    }

    return Math.round((timings.hashMs / timings.childTaskMs) * 1000) / 10;
}

//
// Megabytes hashed per second of hashing, to two decimal places. This is the figure that carries
// across libraries and devices: files per second depends on how big one library's photos happen to
// be, and megabytes per second does not. Zero when nothing was hashed.
//
export function hashMegabytesPerSecond(timings: IImportTimings): number {
    if (timings.hashMs === 0) {
        return 0;
    }

    const megabytes = timings.bytesHashed / (1024 * 1024);
    const seconds = timings.hashMs / 1000;
    return Math.round((megabytes / seconds) * 100) / 100;
}

//
// One stage of an import, with what it cost, ready to be ranked against the others.
//
export interface IImportStageCost {
    // What the stage is called, as it appears in the leaderboard.
    name: string;

    // Total milliseconds the run spent in this stage.
    totalMs: number;

    // That total as a percentage of every stage's total, to one decimal place.
    sharePercent: number;
}

//
// Every stage of an import ranked by what it cost, most expensive first.
//
// This is what says where the time actually goes, and it is the only honest way to choose what to
// optimise: the same import that this ranks was once assumed to be dominated by hashing, and hashing
// turned out to be under 2% of it. A stage that costs nothing is left out rather than listed at
// zero, so the ranking is the work that happened rather than the work that could have.
//
export function rankImportStages(timings: IImportTimings): IImportStageCost[] {
    const stages: IImportStageCost[] = [
        { name: "export", totalMs: timings.exportMs, sharePercent: 0 },
        { name: "hash", totalMs: timings.hashMs, sharePercent: 0 },
        { name: "photoMetadata", totalMs: timings.photoMetadataMs, sharePercent: 0 },
        { name: "videoMetadata", totalMs: timings.videoMetadataMs, sharePercent: 0 },
        { name: "micro", totalMs: timings.microMs, sharePercent: 0 },
        { name: "thumbnail", totalMs: timings.thumbnailMs, sharePercent: 0 },
        { name: "display", totalMs: timings.displayMs, sharePercent: 0 },
        { name: "upload", totalMs: timings.uploadMs, sharePercent: 0 },
        { name: "geocode", totalMs: timings.geocodeMs, sharePercent: 0 },
        { name: "dominantColor", totalMs: timings.dominantColorMs, sharePercent: 0 },
        { name: "probe", totalMs: timings.probeMs, sharePercent: 0 },
        { name: "openStorage", totalMs: timings.openStorageMs, sharePercent: 0 },
        { name: "other", totalMs: timings.otherMs, sharePercent: 0 },
        { name: "databaseWrite", totalMs: timings.databaseWriteMs, sharePercent: 0 },
        { name: "cacheLookup", totalMs: timings.cacheLookupMs, sharePercent: 0 },
        { name: "cacheLoad", totalMs: timings.cacheLoadMs, sharePercent: 0 },
    ].filter(stage => stage.totalMs > 0);

    const measuredMs = stages.reduce((runningTotal, stage) => runningTotal + stage.totalMs, 0);

    return stages
        .map(stage => ({
            name: stage.name,
            totalMs: stage.totalMs,
            sharePercent: measuredMs === 0 ? 0 : Math.round((stage.totalMs / measuredMs) * 1000) / 10,
        }))
        .sort((left, right) => right.totalMs - left.totalMs);
}

//
// The one line an import writes when its counts have moved, holding everything a before-and-after
// comparison needs. Written as JSON so a measurement can be lifted out of a device log without being
// re-typed, and so a field added later does not break whatever is reading it.
//
export function formatImportTimings(timings: IImportTimings): string {
    const summary = {
        totalMs: timings.totalMs,
        childTaskMs: timings.childTaskMs,
        hashMs: timings.hashMs,
        cacheLookupMs: timings.cacheLookupMs,
        cacheLoadMs: timings.cacheLoadMs,
        filesHashed: timings.filesHashed,
        filesFromCache: timings.filesFromCache,
        skippedBeforeOpening: timings.skippedBeforeOpening,
        bytesHashed: timings.bytesHashed,
        exportMs: timings.exportMs,
        metadataMs: timings.metadataMs,
        photoMetadataMs: timings.photoMetadataMs,
        videoMetadataMs: timings.videoMetadataMs,
        microMs: timings.microMs,
        thumbnailMs: timings.thumbnailMs,
        displayMs: timings.displayMs,
        uploadMs: timings.uploadMs,
        geocodeMs: timings.geocodeMs,
        dominantColorMs: timings.dominantColorMs,
        otherMs: timings.otherMs,
        probeMs: timings.probeMs,
        openStorageMs: timings.openStorageMs,
        databaseWriteMs: timings.databaseWriteMs,
        databaseBatches: timings.databaseBatches,
        databaseFlushMs: timings.databaseFlushMs,
        databaseLockWaitMs: timings.databaseLockWaitMs,
        databaseTreeLoadMs: timings.databaseTreeLoadMs,
        databaseAddItemsMs: timings.databaseAddItemsMs,
        databaseMerkleAddMs: timings.databaseMerkleAddMs,
        databaseRecordInsertMs: timings.databaseRecordInsertMs,
        databaseCollectionInsertMs: timings.databaseCollectionInsertMs,
        databaseHashCacheAssetIdMs: timings.databaseHashCacheAssetIdMs,
        databasePerItemOtherMs: timings.databasePerItemOtherMs,
        databaseTreeSaveMs: timings.databaseTreeSaveMs,
        databaseCommitMs: timings.databaseCommitMs,
        databaseStampMs: timings.databaseStampMs,
        photosSeen: timings.photosSeen,
        videosSeen: timings.videosSeen,
        hashSharePercent: hashSharePercent(timings),
        hashMbPerSecond: hashMegabytesPerSecond(timings),
        stages: rankImportStages(timings),
    };
    return `Import timings: ${JSON.stringify(summary)}`;
}
