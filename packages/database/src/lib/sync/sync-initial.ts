import { IAsset } from "../../defs/asset";
import { IApi } from "../api";
import { IAssetSink } from "../asset-sink";
import { IAssetSource } from "../asset-source";
import { IDatabases } from "../databases";
import { IIndexeddbDatabases } from "../indexeddb/indexeddb-databases";
import { visitRecords } from "../visit-records";

interface IProps {
    //
    // Collections to synchronize.
    //
    collectionIds: string[];

    //
    // The interface to the backend.
    //
    api: IApi;

    //
    // Local databases to poplulate.
    //
    indexeddbDatabases: IIndexeddbDatabases;

    //
    // Interface to cloud databases.
    //
    cloudDatabases: IDatabases;

    //
    // The cloud source of assets.
    //
    cloudSource: IAssetSource;

    //
    // The local source of assets.
    //
    indexeddbSource: IAssetSource;

    //
    // The local sink for assets.
    //
    indexeddbSink: IAssetSink;
}

//
// Perform the initial database synchronization.
//
export async function initialSync({ collectionIds, api, indexeddbDatabases, cloudDatabases, cloudSource, indexeddbSource, indexeddbSink }: IProps): Promise<void> {
    for (const collectionId of collectionIds) {
        //
        // Records the latest update id for the collection.
        // This should be done before the initial sync to avoid missing updates.
        //
        const latestUpdateId = await api.getLatestUpdateId(collectionId); 
        if (latestUpdateId !== undefined) {
            //
            // Record the latest update that was received.
            //
            const userDatabase = indexeddbDatabases.database("user");
            userDatabase.collection<any>("last-update-id").setOne(collectionId, { lastUpdateId: latestUpdateId });
        }

        const cloudAssetDatabase = cloudDatabases.database(collectionId);
        const localAssetDatabase = indexeddbDatabases.database(collectionId);
        for (const collectionName of ["metadata", "hashes"]) {
            const localCollection = localAssetDatabase.collection(collectionName);
            const noRecords = await localCollection.none();
            if (noRecords) {    
                //
                // Assume that no records locally means we need to get all records down for this collection.
                //
                await visitRecords<IAsset>(cloudAssetDatabase, collectionName, async (id, record) => {
                    await localCollection.setOne(id, record); // Store it locally.
                });
            }
        }

        //
        // Pre-cache all thumbnails.
        //
        // await visitRecords<IAsset>(cloudAssetDatabase, "metadata", async (id, record) => {
        //     await cacheThumbnail(collectionId, id, indexeddbSource, indexeddbSink, cloudSource);
        // });
    }
}

//
// Pre-caches a thumbnail.
//
// async function cacheThumbnail(collectionId: string, assetId: string, indexeddbSource: IAssetSource, indexeddbSink: IAssetSink, cloudSource: IAssetSource) {
//     const localThumbData = await indexeddbSource.loadAsset(collectionId, assetId, "thumb");
//     if (localThumbData === undefined) {
//         const assetData = await cloudSource.loadAsset(collectionId, assetId, "thumb");
//         if (assetData) {
//             await indexeddbSink.storeAsset(collectionId, assetId, "thumb", assetData);
//             // console.log(`Cached thumbnail for ${collectionId}/${assetId}`);
//         }
//     }
//     else {
//         // console.log(`Thumbnail for ${collectionId}/${assetId} already cached`);
//     }
// }