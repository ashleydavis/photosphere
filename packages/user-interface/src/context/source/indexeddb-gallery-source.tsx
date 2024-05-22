//
// Provides a source of assets for the gallery from indexeddb.
//

import { IAssetRecord } from "../../def/asset-record";
import {  IAssetData, IAssetSource, IIndexeddbDatabases } from "database";

//
// Use the "Indexeddb source" in a component.
//
export function useIndexeddbGallerySource({ indexeddbDatabases }: { indexeddbDatabases: IIndexeddbDatabases }): IAssetSource {


    //
    // Loads data for an asset.
    //
    async function loadAsset(collectionId: string, assetId: string, assetType: string): Promise<IAssetData | undefined> {
        const assetCollection = indexeddbDatabases.database(collectionId);
        const assetRecord = await assetCollection.collection<IAssetRecord>(assetType).getOne(assetId);
        if (!assetRecord) {
            return undefined;
        }

        return assetRecord.assetData;
    }

    return {
        isInitialised: true, // Indexedb is always considered online.
        loadAsset,
    };
}
