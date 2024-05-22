//
// Provides a sink for adding/updating assets to indexeddb.
//

import { IAssetData, IAssetSink, IAssetUpdateRecord, IAssetUploadRecord, IPersistentQueue } from "database";

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
    //fio:
    // outgoingAssetUpdateQueue: IPersistentQueue<IAssetUpdateRecord>;
};

//
// Use the "Local sink" in a component.
//
export function useLocalGallerySink({ indexeddbSink, outgoingAssetUploadQueue }: IProps): IAssetSink {

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
        storeAsset,
    };
}
