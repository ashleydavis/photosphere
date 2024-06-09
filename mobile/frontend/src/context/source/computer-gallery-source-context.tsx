//
// Provides a source of assets for the gallery from the local computer.
//

import { IAssetData, IAssetSource } from "user-interface";
import { IAsset } from "defs";
import { useScan } from "../scan-context";

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
    async function loadAssets(collectionId: string): Promise<IAsset[]> {
        return [];
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
        loadAssets,
        mapHashToAssets,
        loadAsset,
    };
}
