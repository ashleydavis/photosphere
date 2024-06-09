import React, { createContext, ReactNode, useContext, useEffect, useState } from "react";
import { IGalleryItem } from "../lib/gallery-item";
import { useGallery } from "./gallery-context";

export interface IGalleryItemContext {

    //
    // The asset currently loaded.
    //
    asset: IGalleryItem;

    //
    // Set the asset currently loaded.
    //
    setAsset(asset: IGalleryItem): void;

    //
    // Updates the configuration of the asset.
    //
    updateAsset(asset: Partial<IGalleryItem>): Promise<void>;
}

const GalleryItemContext = createContext<IGalleryItemContext | undefined>(undefined);

export interface IProps {

    //
    // Children of the component.
    //
    children: ReactNode | ReactNode[];

    //
    // The asset currently loaded.
    //
    asset: IGalleryItem;

    //
    // Index of the asset in the gallery.
    // This is required for fast updates for the asset back into the full gallery.
    //
    assetIndex: number;
}

export function GalleryItemContextProvider({ children, asset, assetIndex }: IProps) {

    const { updateAsset: updateGalleryAsset } = useGallery();

    //
    // The asset being edited.
    //
    const [_asset, setAsset] = useState<IGalleryItem>(asset);

    //
    // Updates the configuration of the asset.
    //
    async function updateAsset(assetUpdate: Partial<IGalleryItem>): Promise<void> {
        setAsset({
            ..._asset,
            ...assetUpdate,
        });

        await updateGalleryAsset(assetIndex, assetUpdate);
    }

    const value: IGalleryItemContext = {
        asset: _asset,
        setAsset,
        updateAsset,
    };

    return (
        <GalleryItemContext.Provider value={value} >
            {children}
        </GalleryItemContext.Provider>
    );
}

//
// Use the gallery item context in a component.
//
export function useGalleryItem(): IGalleryItemContext {
    const context = useContext(GalleryItemContext);
    if (!context) {
        throw new Error(`Gallery item context is not set! Add GalleryItemContextProvider to the component tree.`);
    }
    return context;
}

