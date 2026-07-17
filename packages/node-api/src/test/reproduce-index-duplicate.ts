import { TestUuidGenerator } from "node-utils";
import { MockTimestampProvider } from "utils";
import { createMediaFileDatabase } from "../lib/media-file-database";
import { openStorage } from "../lib/open-storage";
import type { IBsonCollection, IInternalRecord } from "bdb";
import type { IAsset } from "api";

//
// Reproduces the sort-index duplicate-entry corruption via the exact code path replication and sync
// use to populate a partial replica's index: setInternalRecord -> updateRecordInSortIndexes ->
// updateRecord -> addRecord.
//
// The duplicate is created when an index entry for a record exists but the shard record for it does
// not (the state an interrupted sync/replication can leave: the index write persisted, the shard
// write did not). setInternalRecord then reads existingRecord = undefined, updateRecord skips its
// removal step because there is no old value to locate, and addRecord inserts a SECOND entry at the
// same value in the same leaf. addRecord never checks for an existing entry with the same id.
//
// Usage (from the packages/node-api directory), pointed at a throwaway copy of a database:
//   bun run src/test/reproduce-index-duplicate.ts <databasePath>
//
// If the copy has no index yet, this builds it first (slow); on a copy that already has the index
// it runs quickly.
//

//
// Counts how many index entries exist for a given id across all pages.
//
async function countIndexEntries(metadataCollection: IBsonCollection<IAsset>, targetId: string): Promise<number> {
    let count = 0;
    let nextPageId: string | undefined;
    while (true) {
        const result = await metadataCollection.sortIndex("photoDate", "desc").getPage(nextPageId);
        if (result.records.length === 0) {
            break;
        }
        for (const record of result.records) {
            if (record._id === targetId) {
                count++;
            }
        }
        if (!result.nextPageId) {
            break;
        }
        nextPageId = result.nextPageId;
    }
    return count;
}

async function main(): Promise<void> {
    const databasePath = process.argv[2];
    if (!databasePath) {
        throw new Error("Usage: bun run reproduce-index-duplicate.ts <databasePath>");
    }

    const { storage } = await openStorage(databasePath);
    const database = createMediaFileDatabase(storage, new TestUuidGenerator(), new MockTimestampProvider());
    const metadataCollection = database.metadataCollection;

    // Make sure the index exists (builds it if the copy has none).
    await metadataCollection.sortIndex("photoDate", "desc").ensure(metadataCollection, "date");

    // Pick the first indexed record (it has a photoDate).
    const firstPage = await metadataCollection.sortIndex("photoDate", "desc").getPage("");
    const target = firstPage.records[0];
    const targetId = target._id;
    console.log(`Target id: ${targetId}`);
    console.log(`Index entries for target before: ${await countIndexEntries(metadataCollection, targetId)}`);

    // Read the record so we can re-apply it exactly as replication does.
    const external = await metadataCollection.getOne(targetId);
    if (!external) {
        throw new Error(`Target record not found in store.`);
    }

    // Induce the shard/index desync: delete the record from the shard store only, leaving its index
    // entry in place. This is the end-state an interrupted sync/replication can leave behind.
    const shardId = metadataCollection.getShardId(targetId);
    const shard = metadataCollection.shard(shardId);
    await shard.deleteRecord(targetId);
    console.log(`Removed target from the shard store only (its index entry is left in place).`);

    // Re-apply the record exactly as replication/sync does.
    const reapplied: IInternalRecord = { _id: targetId, fields: { ...(external as unknown as Record<string, unknown>) }, metadata: {} };
    await metadataCollection.setInternalRecord(reapplied);
    await database.bsonDatabase.commit();

    const after = await countIndexEntries(metadataCollection, targetId);
    console.log(`Index entries for target after setInternalRecord: ${after}`);
    console.log(after > 1 ? `REPRODUCED: the index now has a duplicate entry for this id.` : `Not reproduced.`);
}

main().catch(error => {
    console.error(error);
    process.exit(1);
});
