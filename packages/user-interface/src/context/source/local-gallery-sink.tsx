//
// Provides a sink for adding/updating assets to indexeddb.
//

import { IAssetData } from "../../def/asset-data";
import { IDatabaseOp } from "../../def/ops";
import { IGallerySink } from "./gallery-sink";

//
// Use the "Local sink" in a component.
//
export function useLocalGallerySink({ indexeddbSink, outgoingSink }: { indexeddbSink: IGallerySink, outgoingSink: IGallerySink }): IGallerySink {

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
        await outgoingSink.storeAsset(collectionId, assetId, assetType, assetData);
    }

    //
    // Submits operations to change the database.
    //
    async function submitOperations(ops: IDatabaseOp[]): Promise<void> {
        //
        // Update the asset locally.
        //
        await indexeddbSink.submitOperations(ops);

        //
        // Queue the update for upload to the cloud.
        //
        await outgoingSink.submitOperations(ops);
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
        storeAsset,
        submitOperations,
        checkAsset,
    };
}
