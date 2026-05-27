import { retry } from "utils";
import type { ITaskContext } from "task-queue";
import { openStorage } from "./open-storage";
import { createMediaFileDatabase, loadSortIndexes, streamAsset, writeAssetStreamVerified, removeAsset } from "./media-file-database";

//
// Input data for the move-assets background task.
//
export interface IMoveAssetsData {
    //
    // Filesystem path (or S3 path) to the source database.
    //
    sourceDatabasePath: string;

    //
    // Filesystem path (or S3 path) to the destination database.
    //
    destDatabasePath: string;

    //
    // IDs of the assets to move from source to destination.
    //
    assetIds: string[];
}

//
// Result returned by the move-assets task.
//
export interface IMoveAssetsResult {
    //
    // Number of assets successfully moved.
    //
    movedCount: number;
}

//
// Background task handler that moves assets from one database to another.
// Opens both databases directly via storage, copies binary files and metadata,
// then hard-deletes the originals from the source database.
//
export async function moveAssetsHandler(data: IMoveAssetsData, context: ITaskContext): Promise<IMoveAssetsResult> {
    const { sourceDatabasePath, destDatabasePath, assetIds } = data;
    const { uuidGenerator, timestampProvider, sessionId } = context;

    const { storage: sourceStorage, rawStorage: sourceRawStorage } = await openStorage(sourceDatabasePath);
    const sourceDb = createMediaFileDatabase(sourceStorage, uuidGenerator, timestampProvider);
    await loadSortIndexes(sourceStorage, sourceDb.metadataCollection);

    const { storage: destStorage, rawStorage: destRawStorage } = await openStorage(destDatabasePath);
    const destDb = createMediaFileDatabase(destStorage, uuidGenerator, timestampProvider);
    await loadSortIndexes(destStorage, destDb.metadataCollection);

    for (const assetId of assetIds) {
        const metadata = await retry(() => sourceDb.metadataCollection.getOne(assetId));
        if (!metadata) {
            throw new Error(`Asset "${assetId}" not found in source database "${sourceDatabasePath}".`);
        }

        const newAssetId = uuidGenerator.generate();

        for (const assetType of ["thumb", "display", "asset"]) {
            const assetPath = `${assetType}/${assetId}`;
            const exists = await sourceStorage.fileExists(assetPath);
            if (exists) {
                const info = await retry(() => sourceStorage.info(assetPath));
                const stream = await streamAsset(sourceStorage, assetId, assetType);
                await writeAssetStreamVerified(
                    sourceStorage,
                    destStorage,
                    destRawStorage,
                    sessionId,
                    assetId,
                    newAssetId,
                    assetType,
                    info?.contentType,
                    stream,
                    info?.length
                );
            }
        }

        await retry(() => destDb.metadataCollection.updateOne(newAssetId, { ...metadata, _id: newAssetId }, { upsert: true }));
        await destDb.bsonDatabase.commit();

        await removeAsset(
            sourceStorage,
            sourceRawStorage,
            sessionId,
            sourceDb.bsonDatabase,
            sourceDb.metadataCollection,
            assetId,
            true
        );
    }

    return { movedCount: assetIds.length };
}
