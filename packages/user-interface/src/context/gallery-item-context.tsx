import React, { createContext, ReactNode, useContext, useEffect, useState } from "react";
import { IGalleryItem } from "../lib/gallery-item";
import { useApi } from "./api-context";
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
    // Updates certain fields on the asset.
    //
    updateAsset(asset: Partial<IGalleryItem>): void;

    //
    // Sets the description on the asset.
    //
    setDescription(description: string): Promise<void>;

    //
    // Adds a label to the asset.
    //
    addLabel(label: string): Promise<void>;

    //
    // Removes a label from the asset.
    //
    removeLabel(label: string): Promise<void>;
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

    //
    // Interface to the backend.
    //
    const api = useApi();

    //
    // Interface to the gallery.
    //
    const { assets, setAssets } = useGallery();

    //
    // The asset being edited.
    //
    const [_asset, setAsset] = useState<IGalleryItem>(asset);

    //
    // Updates certain fields on the asset.
    //
    function updateAsset(assetUpdate: Partial<IGalleryItem>): void {
        const newAsset = {
            ..._asset,
            ...assetUpdate,
        };
        setAsset(newAsset);

        setAssets([
            ...assets.slice(0, assetIndex),
            newAsset,
            ...assets.slice(assetIndex + 1),
        ]);
    }

    //
    // Debounces the update of the description.
    //
    useEffect(() => {

        console.log(`Triggered timeout to update description asset ${_asset._id}`);

        const timeout = setTimeout(() => {
            console.log(`Updating description for asset ${_asset._id}`);
            api.setDescription(_asset._id, _asset.description || "")
                .catch(err => {
                    console.error(`Failed to update description for asset ${_asset._id}:`);
                    console.error(err)
                });
        }, 1000);

        return () => {
            console.log(`Clearing the timeout for description update.`);
            clearTimeout(timeout);
        };

    }, [_asset.description]);

    //
    // Sets the description on the asset.
    //
    async function setDescription(description: string): Promise<void> {
        //
        // Updating the description triggers a timeout (see useEffect above)
        // to update the description on the backend.
        //
        updateAsset({
            description,
        });
    }

    //
    // Adds a label to the asset.
    //
    async function addLabel(label: string): Promise<void> {

        await api.addLabel(_asset._id, label);

        updateAsset({
            labels: [
                ...(_asset.labels || []),
                label,
            ],
        });
    }

    //
    // Removes a label from the asset.
    //
    async function removeLabel(label: string): Promise<void> {

        await api.removeLabel(_asset._id, label);

        updateAsset({
            labels: (_asset.labels || []).filter(x => x !== label),
        });
    }

    const value: IGalleryItemContext = {
        asset: _asset,
        setAsset,
        updateAsset,
        setDescription,
        addLabel,
        removeLabel,
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

