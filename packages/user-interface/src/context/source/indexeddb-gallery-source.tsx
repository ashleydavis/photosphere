//
// Provides a source of assets for the gallery from indexeddb.
//

import { useRef } from "react";
import { IGallerySource } from "./gallery-source";
import { useApi } from "../api-context";
import { useIndexeddb } from "../indexeddb-context";
import { IUser } from "../../def/user";
import { IAssetData } from "../../def/asset-data";
import { IAsset } from "../../def/asset";

//
// Use the "Indexeddb source" in a component.
//
export function useIndexeddbGallerySource(): IGallerySource {

    const api = useApi();

    const { getAllRecords, getRecord } = useIndexeddb();

    //
    // Loads the user's details.
    //
    async function getUser(): Promise<IUser | undefined> {
        const userId = localStorage.getI("userId");
        if (!userId) {
            return undefined;
        }

        const user = await getRecord<IUser>("user", "user", userId);
        if (!user) {
            return undefined;
        }

        return user;
    }

    //
    // Retreives assets from the source.
    //
    async function getAssets(collectionId: string): Promise<IAsset[]> {
        return await getAllRecords<IAsset>(`collection-${collectionId}`, "metadata");
    }

    //
    // Loads data for an asset.
    //
    async function loadAsset(collectionId: string, assetId: string, assetType: string): Promise<IAssetData | undefined> {
        return await getRecord<IAssetData>(`collection-${collectionId}`, assetType, assetId);
    }

    return {
        isInitialised: true, // Indexedb is always considered online.
        getUser,
        getAssets,
        loadAsset,
    };
}
