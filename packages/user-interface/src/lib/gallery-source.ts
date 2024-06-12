
import { IAsset } from "defs";
import { IAssetData } from "../def/asset-data";
import { IGalleryItem } from "./gallery-item";

//
// Loads gallery items and assets.
//
export interface IGallerySource {

    //
    // Loads gallery items.
    //
    loadGalleryItems(): Promise<IGalleryItem[]>;

    //
    // Checks if an asset is already uploaded.
    //
    checkAssetHash(hash: string): Promise<boolean>;
    
    //
    // Loads data for an asset.
    //
    loadAsset(assetId: string, assetType: string): Promise<IAssetData | undefined>;
}