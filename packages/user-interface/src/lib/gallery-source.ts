
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
    // Maps a hash to the assets already uploaded.
    //
    mapHashToAssets(hash: string): Promise<string[]>;
    
    //
    // Loads data for an asset.
    //
    loadAsset(assetId: string, assetType: string): Promise<IAssetData | undefined>;
}