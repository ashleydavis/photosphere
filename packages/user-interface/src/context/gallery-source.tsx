import { createContext, useContext } from "react";
import { IGalleryItem } from "../lib/gallery-item";
import { IAssetData } from "../def/asset-data";

//
// Interface that provides assets for a gallery.
//
export interface IGallerySource {
    
    //
    // Set to true when the source is initialized.
    //
    isInitialized: boolean;

    //
    // Set to true when the source is readonly and can't be edited.
    //
    isReadOnly: boolean;

    //
    // Assets that have been loaded.
    //
    assets: IGalleryItem[];

    //
    // Adds an asset to the source (if not readonly).
    //
    addAsset(asset: IGalleryItem): Promise<void>;

    //
    // Updates an existing asset.
    //
    updateAsset(assetId: string, partialAsset: Partial<IGalleryItem>): Promise<void>;

    //
    // Checks if an asset is already uploaded.
    //
    checkAssetHash(hash: string): Promise<boolean>;

    //
    // Loads data for an asset.
    //
    loadAsset(assetId: string, assetType: string): Promise<IAssetData | undefined>;

    //
    // Stores an asset.
    //
    storeAsset(assetId: string, assetType: string, assetData: IAssetData): Promise<void>;    
}

export const GallerySourceContext = createContext<IGallerySource | undefined>(undefined);

//
// Use the gallery source in a component.
//
export function useGallerySource(): IGallerySource {
    const context = useContext(GallerySourceContext);
    if (!context) {
        throw new Error(`GallerySourceContext is not set!.`);
    }
    return context;
}