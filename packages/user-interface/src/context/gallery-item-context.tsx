import React, { createContext, ReactNode, useContext, useEffect, useState } from "react";
import { IGalleryItem } from "../lib/gallery-item";
import { useApi } from "./api-context";
import { IGallerySource } from "./source/gallery-source";
import { IGallerySink } from "./source/gallery-sink";

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
    // The source that loads asset into the gallery.
    //
    source: IGallerySource;

    //
    // The sink that uploads and updates assets.
    //
    sink?: IGallerySink;

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

export function GalleryItemContextProvider({ source, sink, children, asset, assetIndex }: IProps) {

    //
    // todo: Register for update to the asset from the source to trigger a render.
    //

    //
    // Interface to the backend.
    //
    const api = useApi();

    //
    // The asset being edited.
    //
    const [_asset, setAsset] = useState<IGalleryItem>(asset);

    //
    // Updates the configuration of the asset.
    //
    async function updateAsset(assetUpdate: Partial<IGalleryItem>): Promise<void> {
        if (!sink) {
            throw new Error(`Cannot edit readonly gallery.`); 
        }

        setAsset({
            ..._asset,
            ...assetUpdate,
        });

        await sink.updateAsset(assetIndex, assetUpdate);
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

