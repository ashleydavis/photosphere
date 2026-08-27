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

    // Whether the cache answered, so no hashing was needed.
    hashFromCache: boolean;
}

//
// A run's timings before it has done anything.
//
export function createEmptyImportTimings(): IImportTimings {
    return {
        totalMs: 0,
        hashMs: 0,
        cacheLookupMs: 0,
        childTaskMs: 0,
        filesHashed: 0,
        filesFromCache: 0,
        skippedBeforeOpening: 0,
        bytesHashed: 0,
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
        totalMs: timings.totalMs,
        hashMs: timings.hashMs + hashFileTiming.hashMs,
        cacheLookupMs: timings.cacheLookupMs + hashFileTiming.cacheLookupMs,
        childTaskMs: timings.childTaskMs + hashFileTiming.taskMs,
        filesHashed: timings.filesHashed + (hashFileTiming.hashFromCache ? 0 : 1),
        filesFromCache: timings.filesFromCache + (hashFileTiming.hashFromCache ? 1 : 0),
        skippedBeforeOpening: timings.skippedBeforeOpening,
        bytesHashed: timings.bytesHashed + hashFileTiming.bytesHashed,
    };
}

//
// Folds one finished upload-asset task into a run's timings. An upload hashes nothing, so all it
// adds is its own time to the child task total that hashing is measured against.
//
export function addUploadAssetTiming(timings: IImportTimings, taskMs: number): IImportTimings {
    return {
        totalMs: timings.totalMs,
        hashMs: timings.hashMs,
        cacheLookupMs: timings.cacheLookupMs,
        childTaskMs: timings.childTaskMs + taskMs,
        filesHashed: timings.filesHashed,
        filesFromCache: timings.filesFromCache,
        skippedBeforeOpening: timings.skippedBeforeOpening,
        bytesHashed: timings.bytesHashed,
    };
}

//
// Stamps the run's wall clock onto its timings, once the run has finished.
//
export function withTotalMs(timings: IImportTimings, totalMs: number): IImportTimings {
    return {
        totalMs,
        hashMs: timings.hashMs,
        cacheLookupMs: timings.cacheLookupMs,
        childTaskMs: timings.childTaskMs,
        filesHashed: timings.filesHashed,
        filesFromCache: timings.filesFromCache,
        skippedBeforeOpening: timings.skippedBeforeOpening,
        bytesHashed: timings.bytesHashed,
    };
}

//
// Records how many items the scanner recognised without opening them, which is a count the scanner
// keeps rather than something the child tasks report.
//
export function withSkippedBeforeOpening(timings: IImportTimings, skippedBeforeOpening: number): IImportTimings {
    return {
        totalMs: timings.totalMs,
        hashMs: timings.hashMs,
        cacheLookupMs: timings.cacheLookupMs,
        childTaskMs: timings.childTaskMs,
        filesHashed: timings.filesHashed,
        filesFromCache: timings.filesFromCache,
        skippedBeforeOpening,
        bytesHashed: timings.bytesHashed,
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
// The one line an import writes when it finishes, holding everything a before-and-after comparison
// needs. Written as JSON so a measurement can be lifted out of a device log without being re-typed,
// and so a field added later does not break whatever is reading it.
//
export function formatImportTimings(timings: IImportTimings): string {
    const summary = {
        totalMs: timings.totalMs,
        childTaskMs: timings.childTaskMs,
        hashMs: timings.hashMs,
        cacheLookupMs: timings.cacheLookupMs,
        filesHashed: timings.filesHashed,
        filesFromCache: timings.filesFromCache,
        skippedBeforeOpening: timings.skippedBeforeOpening,
        bytesHashed: timings.bytesHashed,
        hashSharePercent: hashSharePercent(timings),
        hashMbPerSecond: hashMegabytesPerSecond(timings),
    };
    return `Import timings: ${JSON.stringify(summary)}`;
}
