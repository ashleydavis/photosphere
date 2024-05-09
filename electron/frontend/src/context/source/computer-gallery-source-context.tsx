//
// Provides a source of assets for the gallery from the local computer.
//

import { IGallerySource } from "user-interface/src/context/source/gallery-source";
import { useScan } from "../scan-context";
import { IAsset, IUser } from "user-interface";
import { IAssetData } from "user-interface/build/def/asset-data";

//
// Use the "computer source" in a component.
//
export function useComputerGallerySource(): IGallerySource {

    //
    // The interface to file system scanning.
    //
    const { assets } = useScan();

    //
    // Loads the user's details.
    //
    async function getUser(): Promise<IUser | undefined> {
        return undefined;
    }

    //
    // Retreives assets from the source.
    //
    async function getAssets(): Promise<IAsset[]> {
        //TODO:
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
        getUser,
        getAssets,
        loadAsset,
    };
}
