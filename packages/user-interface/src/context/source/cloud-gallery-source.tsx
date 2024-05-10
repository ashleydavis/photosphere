//
// Provides a source of assets for the gallery from the cloud.
//

import { IGallerySource } from "./gallery-source";
import { IGetAssetsResult, useApi } from "../api-context";
import { IUser } from "../../def/user";
import { IAsset } from "../../def/asset";
import { IAssetData } from "../../def/asset-data";

//
// Use the "Cloud source" in a component.
//
export function useCloudGallerySource(): IGallerySource {

    //
    // Interface to the backend.
    //
    const api = useApi();

    //
    // Loads the user's details.
    //
    async function getUser(): Promise<IUser | undefined> {
        return await api.getUser();
    }

    //
    // Retreives assets from the source.
    //
    async function getAssets(collectionId: string): Promise<IAsset[]> {
        let assets: IAsset[] = [];
        let next: string | undefined = undefined;

        //
        // Load all assets into memory via the paginated REST API.
        //
        while (true) {
            const result: IGetAssetsResult = await api.getAssets(collectionId, next);
            assets = assets.concat(result.assets);            
            next = result.next;
            if (next === undefined) {
                break;
            }
        }

        return assets;        
    }

    //
    // Loads data for an asset.
    //
    async function loadAsset(collectionId: string, assetId: string, assetType: string): Promise<IAssetData | undefined> {
        const assetBlob = await api.getAsset(collectionId, assetId, assetType);
        return {
            contentType: assetBlob.type,
            data: assetBlob,
        };
   }

    return {
        isInitialised: api.isInitialised,
        getUser,
        getAssets,
        loadAsset,
    };
}
