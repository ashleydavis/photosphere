import { IAssetData } from "../def/asset-data";
import { IGalleryItem } from "./gallery-item";

//
// Adds and edits gallery items.
//
export interface IGallerySink {
    //
    // Adds a new gallery item.
    //
    addGalleryItem(galleryItem: IGalleryItem): Promise<void>;

    //
    // Update a gallery item.
    //
    updateGalleryItem(assetId: string, partialGalleryItem: Partial<IGalleryItem>): Promise<void>;

    //
    // Stores an asset.
    //
    storeAsset(assetId: string, assetType: string, assetData: IAssetData): Promise<void>;
}