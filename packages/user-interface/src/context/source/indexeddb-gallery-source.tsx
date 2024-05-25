//
// Provides a source of assets for the gallery from indexeddb.
//

import { IAssetRecord } from "../../def/asset-record";
import {  IAsset, IAssetData, IAssetSource, IHashRecord, IIndexeddbDatabases, IPage } from "database";

//
// Use the "Indexeddb source" in a component.
//
export function useIndexeddbGallerySource({ indexeddbDatabases }: { indexeddbDatabases: IIndexeddbDatabases }): IAssetSource {

    //
    // Loads metadata for all assets.
    //
    async function loadAssets(collectionId: string, max: number, next?: string): Promise<IPage<IAsset>> {
        const assetDatabase = indexeddbDatabases.database(collectionId);
        return await assetDatabase.collection<IAsset>("metadata").getAll(max, next);
    }

    //
    // Maps a hash to the assets already uploaded.
    //
    async function mapHashToAssets(collectionId: string, hash: string): Promise<string[]> {
        const assetCollection = indexeddbDatabases.database(collectionId);
        const hashRecord = await assetCollection.collection<IHashRecord>("hashes").getOne(hash);
        if (!hashRecord) {
            return [];
        }

        return hashRecord.assetIds;
    }

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
        loadAssets,
        mapHashToAssets,
        loadAsset,
    };
}
