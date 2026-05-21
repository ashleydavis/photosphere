# Fix Move Between Databases

## Overview

The "Move to database" feature is broken. `moveToDatabase` in `asset-database-source.tsx` copies binary files via the REST API and soft-deletes from the source (setting `deleted: true`) instead of doing a hard-delete. Binary files remain on source disk and the metadata record is never removed, so reopening the source database still shows the asset. The fix is to replace the entire move implementation with a single `"move-assets"` background task that opens both databases directly via storage, copies binary files and metadata, and hard-deletes from the source -- no REST API involved.

## Issues

## Steps

1. **Create `packages/api/src/lib/move-assets.worker.ts`** -- Define `IMoveAssetsData` with fields `sourceDatabasePath: string`, `destDatabasePath: string`, and `assetIds: string[]`. Define `IMoveAssetsResult` with field `movedCount: number`. Implement `moveAssetsHandler(data, context)`:
   - Call `openStorage(data.sourceDatabasePath)` to get `{ storage: sourceStorage, rawStorage: sourceRawStorage }`.
   - Call `createMediaFileDatabase(sourceStorage, context.uuidGenerator, context.timestampProvider)` and `loadSortIndexes(sourceStorage, sourceDb.metadataCollection)` for the source.
   - Call `openStorage(data.destDatabasePath)` to get `{ storage: destStorage, rawStorage: destRawStorage }`.
   - Call `createMediaFileDatabase(destStorage, context.uuidGenerator, context.timestampProvider)` and `loadSortIndexes(destStorage, destDb.metadataCollection)` for the dest.
   - For each `assetId` in `data.assetIds`:
     - Read the metadata record: `await sourceDb.metadataCollection.getOne(assetId)`. Throw if not found.
     - Generate a new asset ID with `context.uuidGenerator.generate()`.
     - For each asset type in `["thumb", "display", "asset"]`: check if the file exists in source with `sourceStorage.fileExists(`${assetType}/${assetId}`)`. If it does, get its info with `sourceStorage.info(...)`, get a read stream with `streamAsset(sourceStorage, assetId, assetType)`, and write it to dest with `writeAssetStream(destStorage, destRawStorage, context.sessionId, newAssetId, assetType, info.contentType, stream, info.length)`.
     - Write the metadata to dest: `await destDb.metadataCollection.updateOne(newAssetId, { ...metadata, _id: newAssetId }, { upsert: true })` then `await destDb.bsonDatabase.commit()`.
     - Hard-delete from source: `await removeAsset(sourceStorage, sourceRawStorage, context.sessionId, sourceDb.bsonDatabase, sourceDb.metadataCollection, assetId, true)`.
   - Return `{ movedCount: data.assetIds.length }`.

2. **`packages/api/src/lib/task-handlers.ts`** -- Import `moveAssetsHandler` from `"./move-assets.worker"` and add `registerHandler("move-assets", moveAssetsHandler)` inside `initTaskHandlers`.

3. **`packages/api/src/index.ts`** -- Add `export * from "./lib/move-assets.worker"`.

4. **`packages/user-interface/src/context/asset-database-source.tsx`** -- Rewrite `moveToDatabase` to:
   - Create a local `TaskQueue`: `new TaskQueue(new RandomUuidGenerator(), databasePath!)`.
   - Queue the task: `queue.addTask("move-assets", { sourceDatabasePath: databasePath!, destDatabasePath, assetIds } satisfies IMoveAssetsData)`.
   - Await the result with `queue.awaitTask(taskId)`. Throw if status is not `TaskStatus.Succeeded`.
   - Shut down the queue: `queue.shutdown()`.
   - Call `onItemsDeleted.current.invoke({ assetIds })` to update the in-memory gallery state.
   - Keep the existing `log.event(...)` call after the await.
   - Add imports: `TaskQueue`, `TaskStatus` from `"task-queue"` and `IMoveAssetsData` from `"api"`.
   - Remove the now-unused private functions `loadAssetFromDatabase`, `storeAssetToDatabase`, and `addAssetToDatabase`. Keep `loadAsset` -- it is part of the `IGallerySource` public interface and used by gallery image and asset view components.

## Unit Tests

- **`packages/api/src/test/move-assets.worker.test.ts`** (create) -- Add a test that:
  - Creates a source database and imports one asset (with thumb, display, and asset binary files).
  - Calls `moveAssetsHandler` directly with source path, dest path, and the asset ID.
  - Asserts the result `movedCount` is 1.
  - Asserts that the binary files no longer exist in the source database directory.
  - Asserts the source metadata collection has no record for the asset.
  - Asserts the dest database directory contains binary files for the new asset ID.
  - Asserts the dest metadata collection has a record for the new asset ID with the original metadata fields.

## Smoke Tests

- Run the existing Electron smoke test `18-move-file` (`bun run test:electron -- 18`). It:
  - Creates a source database with one asset.
  - Creates an empty destination database.
  - Opens the source database in the app, selects the asset, and clicks "Move to dest-db".
  - Waits for `"Move to database completed: 1 asset moved"`.
  - Reopens the destination database and confirms `"Load assets task completed: 1 assets loaded"`.
  - Reopens the source database and confirms `"Load assets task completed: 0 assets loaded"`.
  - Asserts no errors.

## Verify

- Run `bun run compile` from repo root -- must produce zero TypeScript errors.
- Run `bun run test` from repo root -- all unit tests must pass.
- Run `bun run test:electron -- 18` -- smoke test 18 must pass end-to-end.

## Human Verification

1. Start the app with `bun run dev`.
2. Create a source database and import one photo.
3. Create an empty destination database.
4. In the app, open the source database.
5. Hover over the photo and click the circle in the top-left corner to select it.
6. Click the three-dot menu (top-right) to open the right sidebar.
7. Click "Move to `<dest database name>`".
8. Confirm the photo disappears from the source gallery immediately.
9. Switch to the destination database and confirm the photo appears there.
10. Close and reopen the source database -- the gallery should show 0 photos.
11. Check the source database directory: no binary files should remain for the moved asset.

## Notes

- `removeAsset` handles its own write lock internally, so the handler does not acquire it separately.
- `recordDeleted: true` is passed to `removeAsset` so the deleted asset ID is tracked in `deletedAssetIds` on the merkle tree, consistent with how replication tracks removals for sync.
- `writeAssetStream` also handles its own write lock. Since the binary writes and the `removeAsset` call each acquire and release the write lock independently, they must not be interleaved concurrently -- the sequential loop in the handler ensures this.
- `deleteAssets` remains on the context (soft-delete) as it is used by other consumers. Only `moveToDatabase` changes to use the hard-delete background task.
