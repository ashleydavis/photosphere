//
// Provides a source of assets for the gallery from the local computer.
//

import { IAssetData, IGalleryItem, IGallerySource } from "user-interface";
import { useScan } from "../scan-context";

//
// Use the "computer source" in a component.
//
export function useComputerGallerySource(): IGallerySource {

    //
    // The interface to file system scanning.
    //
    const { assets } = useScan();

    //
    // Loads metadata for all assets.
    //
    async function loadGalleryItems(): Promise<IGalleryItem[]> {
        return [];
    }

    //
    // Maps a hash to the assets already uploaded.
    //
    async function mapHashToAssets(hash: string): Promise<string[]> {
        return [];
    }

    //
    // Loads data for an asset.
    //
    async function loadAsset(assetId: string, assetType: string): Promise<IAssetData | undefined> {
        //TODO: 
        return undefined;
    }

    return {
        loadGalleryItems,
        mapHashToAssets,
        loadAsset,
    };
}
