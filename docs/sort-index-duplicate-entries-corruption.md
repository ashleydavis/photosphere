# Sort index duplicate entries: corruption findings (follow-up)

This documents a data-corruption investigation so it can be picked up later. The exploratory code fix and its test were reverted; this doc is the record of what was found. Nothing here has been repaired on disk yet.

## Summary

The `photoDate`-descending sort index for the metadata collection contains duplicate entries: a handful of assets each have two entries in the same B-tree leaf at the same `photoDate`. Paging the index therefore returns those assets twice, which surfaces in the gallery as a React "two children with the same key" warning and can duplicate a thumbnail. The record store (the source of truth) is clean; only the index is corrupt.

## Affected database

The local `ash-&-ant` database at `/home/ash/photosphere/ash-&-ant`. The findings below were measured against that database.

## What is duplicated

Five assets, each appearing twice in the sort index but only once in the record store:

| asset id | photoDate | record store | sort index |
|---|---|---|---|
| 94530246-ff19-4bb7-afa0-f6df1d546401 | 2025-12-06T09:17:05.616Z | 1 | 2 |
| a829737c-adeb-4813-81fd-c34649f69aa6 | 2025-11-18T09:05:42.933Z | 1 | 2 |
| 467cc5cc-f4e0-4b41-a486-99f14b083bfe | 2024-04-29T13:14:25.000Z | 1 | 2 |
| 01218fd3-0743-44ed-b160-7f7451731ff2 | 2017-10-20T04:20:00.000Z | 1 | 2 |
| 62525ede-d418-446b-abdc-b2c421174afb | 2017-10-20T04:19:44.000Z | 1 | 2 |

The id `a829737c-adeb-4813-81fd-c34649f69aa6` is the one that appeared in the original React duplicate-key warning.

## How they are duplicated

Only in the sort index, nowhere else. Specifically:

- Not duplicated as asset files on disk.
- Not duplicated as database records: the record store (shards) holds exactly one record per id.
- Duplicated only as sort-index entries: each of the five ids has two entries, both in the same leaf node, at the same `photoDate` value.

Measured counts on the `ash-&-ant` database:

- Record store: 109020 records, all ids unique, 0 duplicated records.
- Sort index (`photoDate` desc): 109178 total entries, 109173 unique ids, 5 ids duplicated.

## Files on disk

The corrupt index is the `photoDate` descending index for the `metadata` collection. On the `ash-&-ant` database it lives at:

`/home/ash/photosphere/ash-&-ant/.db/bson/indexes/metadata/photoDate_desc/`

That directory contains `tree.dat` (the B-tree structure and leaf pointers) plus one records file per leaf, each named by its page id. The 5 duplicate entries sit inside three of those leaf files:

| leaf records file | duplicate ids it contains |
|---|---|
| `10e4b5db-88ab-4106-b07c-cb3ace98b095` | `94530246-ff19-4bb7-afa0-f6df1d546401`, `a829737c-adeb-4813-81fd-c34649f69aa6` |
| `0a15e431-80f0-41af-ad79-cd99c69701f7` | `467cc5cc-f4e0-4b41-a486-99f14b083bfe` |
| `2f06a086-5940-46be-ad97-1c28ed92698c` | `01218fd3-0743-44ed-b160-7f7451731ff2`, `62525ede-d418-446b-abdc-b2c421174afb` |

The asset files themselves (`asset/`, `original/`, `display/`, `thumb/`) and the record shards (`.db/bson/collections/`) are not affected.

## Root cause

`SortIndex.addRecord` (packages/bdb/src/lib/sort-index.ts) inserts a new leaf entry without checking whether an entry for the same `_id` already exists in the target leaf. `SortIndex.updateRecord` only removes the previous entry when it is handed an old record whose indexed field value locates it; when that removal step is skipped or misses (for example a `set` op applied via `updateOne(..., { upsert: true })` where the old value is not available), it falls through to `addRecord`, which then adds a second entry at the same value. That second entry is the duplicate.

The prevention fix is to make `addRecord` enforce one entry per `_id` per leaf (remove any existing same-id entry before inserting, and do not increment the entry count on a replacement). This was implemented and proven during investigation, then reverted along with everything else. It still needs to be reapplied as the real prevention fix.

## The database is a partial replica

Confirmed: this database is a partial replica (`isPartial=true`). `/home/ash/photosphere/ash-&-ant/.db/config.json` shows `origin: s3:photosphere-ash-and-ant`, `lastReplicatedAt: 2026-04-21`, `lastSyncedAt: 2026-05-25`. The index leaf files are dated 2026-05-24 to 2026-05-26, so the index was (re)built or updated during the May sync, well after the April replication. The specific corrupt leaf files are not referenced in the merkle tree (`.db/files.dat`), so they were built locally on the replica rather than copied raw from the origin.

How a partial replica gets its index: partial replication (`replicate()` with `partial: true` in packages/node-api/src/lib/replicate.ts) copies only the merkle trees and marks the database partial; it does not copy shard data. Records are then filled in over time by sync, which copies shard files and drives incremental index updates through `IBsonCollection.setInternalRecord` (packages/bdb/src/lib/collection.ts), which calls `updateRecordInSortIndexes(record, existingRecord)` and ultimately `updateRecord` / `addRecord` per record.

## Experiments run (on a /tmp copy of the record store)

Copied the record store (`.db` minus `bson/indexes`) to `/tmp/psi-repro/ash-db` and rebuilt the index there. Results:

- Clean straight build: 103603 unique ids, 0 duplicates.
- Interrupted build (aborted at 50000 records) then resumed from checkpoint with a fresh instance: 103603 unique ids, 0 duplicates.

Both build paths are clean. This disproves the earlier hypothesis that an interrupted-and-resumed build creates the duplicates: the build flushes dirty leaves immediately before saving each checkpoint (packages/bdb/src/lib/sort-index.ts, around lines 989-999), so a resume never reprocesses already-persisted records.

Two anomalies point away from the build and toward the incremental update path:

- A clean build indexes 103603 ids (only records that currently have a `photoDate`), but the live corrupt index has 109173 unique ids: about 5570 more than any build produces. Extra entries for ids with no current `photoDate` can only come from `updateRecord` failing to remove a prior entry when the field value changed to undefined.
- The 5 exact duplicates (same id, same `photoDate`, same leaf) require a second `addRecord` for an already-indexed id without the first entry being removed.

## Reproduced via the replication/sync index-update path

The corruption comes from the incremental index-update path used by sync/replication, `setInternalRecord` -> `updateRecordInSortIndexes` -> `updateRecord` -> `addRecord`, not from building the index.

Reproduced deterministically on the `/tmp` copy with `packages/node-api/src/test/reproduce-index-duplicate.ts`:

- Pick a record that has one index entry.
- Delete that record from the shard store only, leaving its index entry in place. This is the state an interrupted sync/replication leaves: the index write persisted but the shard write did not.
- Call `setInternalRecord` for the record, exactly as `replicateBsonDatabase` does.
- Result: the index now has two entries for that id, at the same `photoDate`, in the same leaf. Output: `before: 1 ... after: 2 ... REPRODUCED`.

Why it happens: `setInternalRecord` reads `existingRecord = shard.record(id)`, which is now `undefined`. `updateRecord(record, undefined)` sees no old value to locate, so it skips its removal step. `addRecord` then inserts a second entry, and `addRecord` never checks whether an entry with the same id already exists in the target leaf. The two enabling defects are:

1. `addRecord` (packages/bdb/src/lib/sort-index.ts, around line 1999) inserts without deduping by `_id`.
2. `updateRecord` only removes the previous entry when it can locate it via the old field value; when `existingRecord` does not reflect the indexed state, removal misses.

The open question is how the shard/index desync arises naturally during a real sync. It requires the index entry to be persisted while the shard record for it is not, across an interruption. Both are committed during replication/sync, but through different machinery, so an interruption between them can leave exactly this state. Confirming the precise interruption window is the remaining work; the duplicate-creation mechanism itself is confirmed.

## Still unconfirmed

Separately from the 5 duplicates, the live index has far more unique ids than a clean build (109173 vs 103603) and more than the record store (109020). That indicates orphaned or stale index entries as well. Not yet fully characterised.

## Scripts kept from this investigation

All three scripts are in the repo (they import repo packages, so run them from the `packages/node-api` directory) and each has a header comment explaining what it does and why. They operate on whatever database path you pass; for anything that writes, pass a throwaway copy. The record-store copy used during this investigation is at `/tmp/psi-repro/ash-db` (also see `/tmp/psi-repro/HOW-TO-RUN.md`).

Make a fresh throwaway copy of the record store (excludes the large index dir):

```
rm -rf /tmp/psi-repro/ash-db && mkdir -p /tmp/psi-repro/ash-db
rsync -a --exclude 'bson/indexes' "/home/ash/photosphere/ash-&-ant/.db" /tmp/psi-repro/ash-db/
```

`packages/node-api/src/test/reproduce-index-duplicate.ts` — reproduces a duplicate via the replication/sync path (`setInternalRecord`). Writes to the copy, so use a fresh copy for a clean `before: 1` result.

```
cd packages/node-api
bun run src/test/reproduce-index-duplicate.ts /tmp/psi-repro/ash-db
```

`packages/node-api/src/test/index-build-experiment.ts` — clean and interrupted-then-resumed index builds (both produce 0 duplicates, showing the build is not the cause). Delete the index dir first so it builds fresh.

```
cd packages/node-api
rm -rf /tmp/psi-repro/ash-db/.db/bson/indexes
bun run src/test/index-build-experiment.ts /tmp/psi-repro/ash-db clean
rm -rf /tmp/psi-repro/ash-db/.db/bson/indexes
bun run src/test/index-build-experiment.ts /tmp/psi-repro/ash-db resume 50000
```

The read-only duplicate identifier below can be run directly against the real database (it never writes). Save it as `packages/node-api/src/test/find-index-duplicates.ts`:

```
cd packages/node-api
bun run src/test/find-index-duplicates.ts "/home/ash/photosphere/ash-&-ant"
```

## Suggested follow-up

1. Fix the enabling defect in the index. Two options, both worth doing: make `SortIndex.addRecord` enforce one entry per `_id` per leaf (remove any existing same-id entry before inserting), and make `updateRecord` remove the previous entry by id rather than depending on the old field value to locate it. The `addRecord` change alone stops the reproduced duplication.
2. Investigate the shard/index persistence ordering during replication/sync so an interruption cannot leave an index entry without its shard record. This is the natural trigger for the reproduced desync.
3. Confirm the shard-vs-index count gap (index 109173 unique vs record store 109020, and vs clean build 103603) to characterise the orphaned/stale entries as well.
4. Heal the existing on-disk corruption by rebuilding the sort index from the record store (the clean source of truth). The rebuild primitives already exist: `sortIndex.drop()` followed by `ensureSortIndex(metadataCollection)`, as used by the upgrade command in apps/cli/src/cmd/upgrade.ts. Expose this as a CLI command or repair step and run it against the affected database.
5. Consider having `verify` / `check` detect duplicate and orphaned index entries so this class of corruption is caught automatically.

## Standalone snippet to identify the duplicates

This script opens a database read-only, iterates the record store and pages the `photoDate` sort index, and prints which ids are duplicated in the index (and how many entries each has in the store versus the index). It only reads, never writes.

Save it as `packages/node-api/src/test/find-index-duplicates.ts` and run it with `bun run src/test/find-index-duplicates.ts "<database path>"` from the `packages/node-api` directory. For the affected database the path is `/home/ash/photosphere/ash-&-ant`.

```ts
import { TestUuidGenerator } from "node-utils";
import { MockTimestampProvider } from "utils";
import { createMediaFileDatabase, createLazyDatabaseStorage, isDatabasePartial } from "../lib/media-file-database";
import { openStorage } from "../lib/open-storage";

//
// Reports which asset ids are duplicated in the photoDate sort index versus the record store.
// Read-only: it never mutates the database.
//
async function main(): Promise<void> {
    const databasePath = process.argv[2];
    if (!databasePath) {
        throw new Error("Usage: bun run find-index-duplicates.ts <databasePath>");
    }

    const uuidGenerator = new TestUuidGenerator();
    const timestampProvider = new MockTimestampProvider();

    const { storage: plainStorage, s3Config, storageOptions } = await openStorage(databasePath);
    const isPartial = await isDatabasePartial(databasePath, s3Config, storageOptions);
    const storage = isPartial
        ? await createLazyDatabaseStorage(databasePath, s3Config, storageOptions)
        : plainStorage;

    const database = createMediaFileDatabase(storage, uuidGenerator, timestampProvider);
    const metadataCollection = database.metadataCollection;

    //
    // Count occurrences of each id in the record store (shards).
    //
    const recordCounts = new Map<string, number>();
    for await (const record of metadataCollection.iterateRecords()) {
        recordCounts.set(record._id, (recordCounts.get(record._id) || 0) + 1);
    }

    //
    // Count occurrences of each id across the photoDate-desc sort index pages.
    //
    const indexCounts = new Map<string, number>();
    let nextPageId: string | undefined;
    while (true) {
        const result = await metadataCollection.sortIndex("photoDate", "desc").getPage(nextPageId);
        if (result.records.length === 0) {
            break;
        }
        for (const record of result.records) {
            indexCounts.set(record._id, (indexCounts.get(record._id) || 0) + 1);
        }
        if (!result.nextPageId) {
            break;
        }
        nextPageId = result.nextPageId;
    }

    const duplicatedIndex = Array.from(indexCounts.entries()).filter(([, count]) => count > 1);
    console.log(`record store: uniqueIds=${recordCounts.size}`);
    console.log(`sort index:   uniqueIds=${indexCounts.size} duplicatedIds=${duplicatedIndex.length}`);
    for (const [id, indexCount] of duplicatedIndex) {
        console.log(`  ${id}: recordStore=${recordCounts.get(id) || 0} index=${indexCount}`);
    }
}

main().catch(error => {
    console.error(error);
    process.exit(1);
});
```

Expected output for the `ash-&-ant` database (as found during this investigation):

```
record store: uniqueIds=109020
sort index:   uniqueIds=109173 duplicatedIds=5
  94530246-ff19-4bb7-afa0-f6df1d546401: recordStore=1 index=2
  a829737c-adeb-4813-81fd-c34649f69aa6: recordStore=1 index=2
  467cc5cc-f4e0-4b41-a486-99f14b083bfe: recordStore=1 index=2
  01218fd3-0743-44ed-b160-7f7451731ff2: recordStore=1 index=2
  62525ede-d418-446b-abdc-b2c421174afb: recordStore=1 index=2
```
