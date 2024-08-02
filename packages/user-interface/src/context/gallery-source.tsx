import { createContext, useContext } from "react";
import { IGalleryItem } from "../lib/gallery-item";
import { IAssetData } from "../def/asset-data";
import { IAsset } from "defs";
import { IObservable } from "../lib/subscription";

export interface IAssetDataLoad extends IAssetData {
    //
    // The source of the asset data.
    //
    source: "local" | "cloud";
}

export interface IGalleryItemMap {
    [assetId: string]: IGalleryItem;
}

// 
// Notifies of gallery items that were updated.
//
export interface IItemsUpdate {
    //
    // The IDs of updated items.
    //
    assetIds: string[];
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
    // Set to true while working on something.
    //
    isWorking: boolean;

    //
    // Set to true when the source is readonly and can't be edited.
    //
    isReadOnly: boolean;

    //
    // Assets that have been loaded.
    //
    getAssets(): IGalleryItemMap;

    //
    // Subscribes to resets of the gallery.
    //
    onReset: IObservable<void>;

    //
    // Subscribes to new gallery items.
    //
    onNewItems: IObservable<IGalleryItem[]>;

    //
    // Subscribes to gallery item updates.
    //
    onItemsUpdated: IObservable<IItemsUpdate>;

    //
    // Subscribes to gallery item deletions.
    //
    onItemsDeleted: IObservable<IItemsUpdate>;

    //
    // Adds an asset to the source.
    //
    addAsset(asset: IGalleryItem): void;

    //
    // Updates an existing asset.
    //
    updateAsset(assetId: string, partialAsset: Partial<IGalleryItem>): Promise<void>;

    //
    // Update multiple assets with persisted database changes.
    //
    updateAssets(assetUpdates: { assetId: string, partialAsset: Partial<IGalleryItem>}[]): Promise<void>;

    //
    // Adds an array value to the asset.
    //
    addArrayValue(assetId: string, field: string, value: any): Promise<void>;

    //
    // Removes an array value from the asset.
    //
    removeArrayValue(assetId: string, field: string, value: any): Promise<void>;

    //
    // Deletes the assets.
    //
    deleteAssets(assetIds: string[]): Promise<void>;

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

    //
    // Gets a gallery item by id.
    //
    getItemById(assetId: string): IGalleryItem | undefined;
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