import { TestUuidGenerator } from "node-utils";
import { MockTimestampProvider } from "utils";
import { createMediaFileDatabase } from "../lib/media-file-database";
import { openStorage } from "../lib/open-storage";
import type { IBsonCollection } from "bdb";
import type { IAsset } from "api";

//
// Experiment harness for the sort-index duplicate-entry investigation.
//
// Rebuilds the photoDate sort index on a copy of a database and reports how many asset ids end up
// duplicated in the index. Supports a clean build and an interrupted-then-resumed build so the two
// can be compared. Read/writes only the copy it is pointed at; point it at a throwaway copy.
//
// Usage (from the packages/node-api directory):
//   bun run src/test/index-build-experiment.ts <databasePath> [clean|resume] [abortAtRecords]
//
// Before each run, delete the index directory in the copy so the build starts fresh:
//   rm -rf <databasePath>/.db/bson/indexes
//

//
// Thrown to abort a build partway through (resume mode).
//
class AbortBuild extends Error {}

//
// Counts and prints ids that appear more than once across all index pages.
//
async function reportIndexDuplicates(metadataCollection: IBsonCollection<IAsset>): Promise<void> {
    const counts = new Map<string, number>();
    let nextPageId: string | undefined;
    while (true) {
        const result = await metadataCollection.sortIndex("photoDate", "desc").getPage(nextPageId);
        if (result.records.length === 0) {
            break;
        }
        for (const record of result.records) {
            counts.set(record._id, (counts.get(record._id) || 0) + 1);
        }
        if (!result.nextPageId) {
            break;
        }
        nextPageId = result.nextPageId;
    }
    const duplicated = Array.from(counts.entries()).filter(([, count]) => count > 1);
    console.log(`index: uniqueIds=${counts.size} duplicatedIds=${duplicated.length}`);
    for (const [id, count] of duplicated.slice(0, 20)) {
        console.log(`  ${id}: ${count}`);
    }
}

//
// Builds the photoDate index once, straight through.
//
async function cleanBuild(databasePath: string): Promise<void> {
    const { storage } = await openStorage(databasePath);
    const database = createMediaFileDatabase(storage, new TestUuidGenerator(), new MockTimestampProvider());
    console.log(`Clean build...`);
    await database.metadataCollection.sortIndex("photoDate", "desc").ensure(database.metadataCollection, "date");
    console.log(`Clean build complete.`);
    await reportIndexDuplicates(database.metadataCollection);
}

//
// Builds the photoDate index, aborts near abortAt records, then resumes with a fresh instance.
//
async function resumeBuild(databasePath: string, abortAt: number): Promise<void> {
    const { storage } = await openStorage(databasePath);

    console.log(`Build #1: building, will abort near ${abortAt} records...`);
    const database1 = createMediaFileDatabase(storage, new TestUuidGenerator(), new MockTimestampProvider());
    const index1 = database1.metadataCollection.sortIndex("photoDate", "desc");
    (index1 as unknown as { type: string }).type = "date";
    try {
        await index1.build(database1.metadataCollection, (message: string) => {
            const match = message.match(/^Indexed (\d+) records/);
            if (match && parseInt(match[1], 10) >= abortAt) {
                throw new AbortBuild(`aborting at ${match[1]} records`);
            }
        });
        console.log(`Build #1 completed without aborting (abortAt too high?).`);
    }
    catch (error) {
        if (error instanceof AbortBuild) {
            console.log(`Build #1 aborted: ${error.message}`);
        }
        else {
            throw error;
        }
    }

    console.log(`Build #2: resuming from checkpoint with a fresh instance...`);
    const database2 = createMediaFileDatabase(storage, new TestUuidGenerator(), new MockTimestampProvider());
    const index2 = database2.metadataCollection.sortIndex("photoDate", "desc");
    (index2 as unknown as { type: string }).type = "date";
    await index2.build(database2.metadataCollection);
    console.log(`Build #2 complete.`);
    await reportIndexDuplicates(database2.metadataCollection);
}

async function main(): Promise<void> {
    const databasePath = process.argv[2];
    const mode = process.argv[3] || "clean";
    const abortAt = parseInt(process.argv[4] || "50000", 10);
    if (!databasePath) {
        throw new Error("Usage: bun run index-build-experiment.ts <databasePath> [clean|resume] [abortAtRecords]");
    }

    if (mode === "resume") {
        await resumeBuild(databasePath, abortAt);
    }
    else {
        await cleanBuild(databasePath);
    }
}

main().catch(error => {
    console.error(error);
    process.exit(1);
});
