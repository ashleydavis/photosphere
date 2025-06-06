//
// Provides a source of assets for the gallery from the local computer.
//

import { IGalleryItem } from "user-interface";
import { useScan } from "../scan-context";

//
// Use the "computer source" in a component.
//
export function useComputerGallerySource(): unknown {

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
    async function checkAssetHash(hash: string): Promise<boolean> {
        return false;
    }

    //
    // Loads data for an asset.
    //
    async function loadAsset(assetId: string, assetType: string): Promise<Blob | undefined> {
        //TODO: 
        return undefined;
    }

    return {
        loadGalleryItems,
        checkAssetHash,
        loadAsset,
    };
}
