//
// Provides a source of assets for the gallery from the local computer.
//

import { useScan } from "../scan-context";
import { IAsset, IAssetData, IAssetSource, IPage, IUser } from "database";

//
// Use the "computer source" in a component.
//
export function useComputerGallerySource(): IAssetSource {

    //
    // The interface to file system scanning.
    //
    const { assets } = useScan();

    //
    // Loads metadata for all assets.
    //
    async function loadAssets(collectionId: string, max: number, next?: string): Promise<IPage<IAsset>> {
        return {
            records: [],
            next: undefined,
        };
    }

    //
    // Maps a hash to the assets already uploaded.
    //
    async function mapHashToAssets(collectionId: string, hash: string): Promise<string[]> {
        return [];
    }

    //
    // Loads data for an asset.
    //
    async function loadAsset(collectionId: string, assetId: string, assetType: string): Promise<IAssetData | undefined> {
        //TODO: 
        return undefined;
    }

    return {
        isInitialised: false,
        loadAssets,
        mapHashToAssets,
        loadAsset,
    };
}
