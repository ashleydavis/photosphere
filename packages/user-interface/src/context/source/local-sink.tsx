//
// Provides a sink for adding/updating assets to indexeddb.
//

import { IDatabaseOp } from "defs";
import { IAssetSink } from "../../lib/asset-sink";
import { IPersistentQueue } from "../../lib/sync/persistent-queue";
import { IAssetUploadRecord } from "../../lib/sync/asset-upload-record";
import { IAssetUpdateRecord } from "../../lib/sync/asset-update-record";
import { IAssetData } from "../../def/asset-data";
import { IIndexeddbDatabases } from "../../lib/indexeddb/indexeddb-databases";
import { applyOperations } from "../../lib/apply-operation";
import { IAssetRecord } from "../../def/asset-record";

export interface IProps { 
    //
    // Queues outgoing asset uploads.
    //
    outgoingAssetUploadQueue: IPersistentQueue<IAssetUploadRecord>;

    //
    // Queues outgoing asset updates.
    //
    outgoingAssetUpdateQueue: IPersistentQueue<IAssetUpdateRecord>;

    //
    // Indexeddb databases.
    //
    indexeddbDatabases: IIndexeddbDatabases;
};

//
// Use the "Local sink" in a component.
//
export function useLocalGallerySink({ outgoingAssetUploadQueue, outgoingAssetUpdateQueue, indexeddbDatabases }: IProps): IAssetSink {

    //
    // Submits operations to change the database.
    //
    async function submitOperations(ops: IDatabaseOp[]): Promise<void> {
        //
        // Updates the local database.
        //
        await applyOperations(indexeddbDatabases, ops);        

        //
        // Queue the updates for upload to the cloud.
        //
        await outgoingAssetUpdateQueue.add({ ops });       
    }

    //
    // Stores an asset.
    //
    async function storeAsset(collectionId: string, assetId: string, assetType: string, assetData: IAssetData): Promise<void> {
        // 
        // Store the asset locally.
        //
        const assetCollection = indexeddbDatabases.database(collectionId);
        await assetCollection.collection<IAssetRecord>(assetType).setOne(assetId, {
            _id: assetId,
            storeDate: new Date(),
            assetData,
        });

        // 
        // Queue the asset for upload to the cloud.
        //
        await outgoingAssetUploadQueue.add({
            setId: collectionId,
            assetId,
            assetType,
            assetData,
        });
    }

    return {
        submitOperations,
        storeAsset,
    };
}
