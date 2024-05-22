//
// Provides a sink for adding/updating assets to indexeddb.
//

import { IAssetRecord } from "../../def/asset-record";
import { IAssetData, IAssetSink, IIndexeddbDatabases } from "database";

//
// Use the "Indexeddb sink" in a component.
//
export function useIndexeddbGallerySink({ indexeddbDatabases }: { indexeddbDatabases: IIndexeddbDatabases }): IAssetSink {

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
        storeAsset,
    };
}
