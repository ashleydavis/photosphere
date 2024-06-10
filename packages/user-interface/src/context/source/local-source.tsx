//
// Provides a source of assets for the gallery from indexeddb.
//

import { IAsset } from "defs";
import { IAssetData } from "../../def/asset-data";
import { IAssetRecord } from "../../def/asset-record";
import { IHashRecord } from "../../def/hash-record";
import { IGallerySource } from "../../lib/gallery-source";
import { useOnline } from "../../lib/use-online";
import { IApi } from "../api-context";
import { IGalleryItem } from "../../lib/gallery-item";
import { IDatabase } from "../../lib/database/database";

export interface IProps {
    //
    // The currently viewed set.
    //
    setId: string | undefined;
    
    //
    // The local indexeddb database.
    //
    database: IDatabase;

    //
    // Interface to the backend.
    //
    api: IApi;
}

//
// Use the "Local source" in a component.
//
export function useLocalGallerySource({ setId, database, api }: IProps): IGallerySource {

    const { isOnline } = useOnline();

    //
    // Loads gallery items.
    //
    async function loadGalleryItems(): Promise<IGalleryItem[]> {
        if (!setId) {
            throw new Error("No set id provided.");
        }

        const assets = await database.collection<IAsset>("metadata").getAllByIndex("setId", setId);
        return assets.map((asset) => {
            return {
                ...asset,
            };
        });
    }

    //
    // Maps a hash to the assets already uploaded.
    //
    async function mapHashToAssets(hash: string): Promise<string[]> {
        if (!setId) {
            throw new Error("No set id provided.");
        }

        const hashRecord = await database.collection<IHashRecord>("hashes").getOne(hash);
        if (!hashRecord) {
            return [];
        }

        return hashRecord.assetIds;
    }

    //
    // Loads data for an asset.
    //
    async function loadAsset(assetId: string, assetType: string): Promise<IAssetData | undefined> {
        if (!setId) {
            throw new Error("No set id provided.");
        }

        const assetRecord = await database.collection<IAssetRecord>(assetType).getOne(assetId);
        if (assetRecord) {
            return assetRecord.assetData;
        }

        if (!isOnline) {
            return undefined;
        }
        
        // Fallback to cloud.
        const assetBlob = await api.getAsset(setId, assetId, assetType);
        return {
            contentType: assetBlob.type,
            data: assetBlob,
        };
    }

    return {
        loadGalleryItems,
        mapHashToAssets,
        loadAsset,
    };
}
