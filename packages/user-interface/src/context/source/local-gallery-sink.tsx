//
// Provides a sink for adding/updating assets to indexeddb.
//

import { ICollectionOps, IOpSelection } from "../../def/ops";
import { IGallerySink } from "./gallery-sink";

//
// Use the "Local sink" in a component.
//
export function useLocalGallerySink({ indexeddbSink, outgoingSink }: { indexeddbSink: IGallerySink, outgoingSink: IGallerySink }): IGallerySink {

    //
    // Uploads an asset.
    //
    async function uploadAsset(collectionId: string, assetId: string, assetType: string, contentType: string, data: Blob): Promise<void> {
        // 
        // Store the asset locally.
        //
        await indexeddbSink.uploadAsset(collectionId, assetId, assetType, contentType, data);

        // 
        // Queue the asset for upload to the cloud.
        //
        await outgoingSink.uploadAsset(collectionId, assetId, assetType, contentType, data);
    }

    //
    // Submits operations to change the database.
    //
    async function submitOperations(collectionOps: ICollectionOps): Promise<void> {
        //
        // Update the asset locally.
        //
        await indexeddbSink.submitOperations(collectionOps);

        //
        // Queue the update for upload to the cloud.
        //
        await outgoingSink.submitOperations(collectionOps);
    }

    //
    // Check if asset has already been uploaded with a particular hash.
    //
    async function checkAsset(collectionId: string, hash: string): Promise<string | undefined> {       
        const result = await indexeddbSink.checkAsset(collectionId, hash);
        if (result) {
            return result;
        }

        return await outgoingSink.checkAsset(collectionId, hash);
    }

    return {
        uploadAsset,
        submitOperations,
        checkAsset,
    };
}
