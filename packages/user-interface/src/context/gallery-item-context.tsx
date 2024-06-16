import React, { createContext, ReactNode, useContext, useEffect, useState } from "react";
import { IGalleryItem } from "../lib/gallery-item";
import { useGallery } from "./gallery-context";
import { set } from "lodash";

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

    //
    // Adds an array value to the asset.
    //
    addArrayValue(key: string, value: string): Promise<void>;

    //
    // Removes an array value from the asset.
    //
    removeArrayValue(key: string, value: string): Promise<void>;
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
}

export function GalleryItemContextProvider({ children, asset }: IProps) {

    const { updateGalleryItem, addArrayValue: _addArrayValue, removeArrayValue: _removeArrayValue  } = useGallery();

    //
    // The asset being edited.
    //
    const [_asset, setAsset] = useState<IGalleryItem>(asset);

    //
    // Updates the configuration of the asset.
    //
    async function updateAsset(assetUpdate: Partial<IGalleryItem>): Promise<void> {
        if (asset.setIndex === undefined) {
            throw new Error(`Asset set index is not set!`);
        }

        setAsset({
            ..._asset,
            ...assetUpdate,
        });

        await updateGalleryItem(asset.setIndex, assetUpdate);
    }

    //
    // Adds an array value to the asset.
    //
    async function addArrayValue(field: string, value: any): Promise<void> {
        if (asset.setIndex === undefined) {
            throw new Error(`Asset set index is not set!`);
        }

        const updatedAsset: any = { ..._asset };
        if (updatedAsset[field] === undefined) {
            updatedAsset[field] = [];
        }
        updatedAsset[field] = updatedAsset[field].filter((item: any) => item !== value);
        updatedAsset[field].push(value);
        setAsset(updatedAsset);
        console.log(`Updated asset:`); //fio:
        console.log(updatedAsset); //fio:

        await _addArrayValue(asset.setIndex, field, value);
    }

    //
    // Removes an array value from the asset.
    //
    async function removeArrayValue(field: string, value: any): Promise<void> {
        if (asset.setIndex === undefined) {
            throw new Error(`Asset set index is not set!`);
        }

        const updatedAsset: any = { ..._asset };
        if (updatedAsset[field] === undefined) {
            updatedAsset[field] = [];
        }
        updatedAsset[field] = updatedAsset[field].filter((item: any) => item !== value);
        setAsset(updatedAsset);

        await _removeArrayValue(asset.setIndex, field, value);
    }

    const value: IGalleryItemContext = {
        asset: _asset,
        setAsset,
        updateAsset,
        addArrayValue,
        removeArrayValue,
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

