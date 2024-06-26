import { createContext, useContext } from "react";
import { IGalleryItem } from "../lib/gallery-item";
import { IAssetData } from "../def/asset-data";

export interface IAssetDataLoad extends IAssetData {
    //
    // The source of the asset data.
    //
    source: "local" | "cloud";
}

//
// Interface that provides assets for a gallery.
//
export interface IGallerySource {
    
    //
    // Set to true while assets are being loaded.
    //
    isLoading: boolean;

    //
    // Set to true when the source is readonly and can't be edited.
    //
    isReadOnly: boolean;

    //
    // Assets that have been loaded.
    //
    assets: IGalleryItem[];

    //
    // Adds an asset to the source.
    //
    addAsset(asset: IGalleryItem): Promise<void>;

    //
    // Updates an existing asset.
    //
    updateAsset(assetIndex: number, partialAsset: Partial<IGalleryItem>): Promise<void>;

    //
    // Adds an array value to the asset.
    //
    addArrayValue(assetIndex: number, field: string, value: any): Promise<void>;

    //
    // Removes an array value from the asset.
    //
    removeArrayValue(assetIndex: number, field: string, value: any): Promise<void>;    

    //
    // Checks if an asset is already uploaded.
    //
    checkAssetHash(hash: string): Promise<boolean>;

    //
    // Loads data for an asset.
    //
    loadAsset(assetId: string, assetType: string): Promise<IAssetDataLoad | undefined>;

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