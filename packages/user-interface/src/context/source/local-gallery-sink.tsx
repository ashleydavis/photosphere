//
// Provides a sink for adding/updating assets to indexeddb.
//

import { IAssetData, IAssetSink, IAssetUpdateRecord, IAssetUploadRecord, IDatabaseOp, IPersistentQueue } from "database";

export interface IProps { 
    //
    // Used to forward assets and updates to indexeddb.
    //
    indexeddbSink: IAssetSink;

    //
    // Queues outgoing asset uploads.
    //
    outgoingAssetUploadQueue: IPersistentQueue<IAssetUploadRecord>;

    //
    // Queues outgoing asset updates.
    //
    outgoingAssetUpdateQueue: IPersistentQueue<IAssetUpdateRecord>;
};

//
// Use the "Local sink" in a component.
//
export function useLocalGallerySink({ indexeddbSink, outgoingAssetUploadQueue, outgoingAssetUpdateQueue }: IProps): IAssetSink {

    //
    // Submits operations to change the database.
    //
    async function submitOperations(ops: IDatabaseOp[]): Promise<void> {
        //
        // Updates the local database.
        //
        await indexeddbSink.submitOperations(ops);

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
        await indexeddbSink.storeAsset(collectionId, assetId, assetType, assetData);

        // 
        // Queue the asset for upload to the cloud.
        //
        await outgoingAssetUploadQueue.add({
            collectionId,
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
