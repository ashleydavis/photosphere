//
// Provides a sink for adding/updating assets to indexeddb.
//

import { IAssetRecord } from "../../def/asset-record";
import { IAssetData, IAssetSink, IDatabaseOp, IIndexeddbDatabases, applyOperations } from "database";

//
// Use the "Indexeddb sink" in a component.
//
export function useIndexeddbGallerySink({ indexeddbDatabases }: { indexeddbDatabases: IIndexeddbDatabases }): IAssetSink {

    //
    // Submits operations to change the database.
    //
    async function submitOperations(ops: IDatabaseOp[]): Promise<void> {
        await applyOperations(indexeddbDatabases, ops);        
    }

    //
    // Stores an asset.
    //
    async function storeAsset(collectionId: string, assetId: string, assetType: string, assetData: IAssetData): Promise<void> {
        const assetCollection = indexeddbDatabases.database(collectionId);
        await assetCollection.collection<IAssetRecord>(assetType).setOne(assetId, {
            _id: assetId,
            storeDate: new Date(),
            assetData,
        });
    }

    return {
        submitOperations,
        storeAsset,
    };
}
