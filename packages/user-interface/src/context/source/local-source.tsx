//
// Provides a source of assets for the gallery from indexeddb.
//

import { IAsset } from "defs";
import { IAssetData } from "../../def/asset-data";
import { IAssetRecord } from "../../def/asset-record";
import { IHashRecord } from "../../def/hash-record";
import { IApi } from "../../lib/api";
import { IAssetSource } from "../../lib/asset-source";
import { IIndexeddbDatabases } from "../../lib/indexeddb/indexeddb-databases";
import { useOnline } from "../../lib/use-online";

//
// Use the "Local source" in a component.
//
export function useLocalGallerySource({ indexeddbDatabases, api }: { indexeddbDatabases: IIndexeddbDatabases, api: IApi }): IAssetSource {

    const { isOnline } = useOnline();

    //
    // Loads metadata for all assets.
    //
    async function loadAssets(collectionId: string): Promise<IAsset[]> {
        const assetDatabase = indexeddbDatabases.database(collectionId);
        return await assetDatabase.collection<IAsset>("metadata").getAll();
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
        if (assetRecord) {
            return assetRecord.assetData;
        }

        if (!isOnline) {
            return undefined;
        }
        
        // Fallback to cloud.
        const assetBlob = await api.getAsset(collectionId, assetId, assetType);
        return {
            contentType: assetBlob.type,
            data: assetBlob,
        };
    }

    return {
        loadAssets,
        mapHashToAssets,
        loadAsset,
    };
}
