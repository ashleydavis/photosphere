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
    updateAsset(asset: Partial<IGalleryItem>): void;

    //
    // Adds an array value to the asset.
    //
    addArrayValue(key: string, value: string): void;

    //
    // Removes an array value from the asset.
    //
    removeArrayValue(key: string, value: string): void;

    //
    // Deletes the asset in question.
    //
    deleteAsset(): void;
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

    const { updateGalleryItem, addArrayValue: _addArrayValue, removeArrayValue: _removeArrayValue, deleteAsset: _deleteAsset  } = useGallery();

    //
    // The asset being edited.
    //
    const [_asset, setAsset] = useState<IGalleryItem>(asset);

    //
    // Updates the configuration of the asset.
    //
    function updateAsset(assetUpdate: Partial<IGalleryItem>): void {
        if (asset.setIndex === undefined) {
            throw new Error(`Asset set index is not set!`);
        }

        setAsset({
            ..._asset,
            ...assetUpdate,
        });

        updateGalleryItem(asset.setIndex, assetUpdate);
    }

    //
    // Adds an array value to the asset.
    //
    function addArrayValue(field: string, value: any): void {
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

        _addArrayValue(asset.setIndex, field, value);
    }

    //
    // Removes an array value from the asset.
    //
    function removeArrayValue(field: string, value: any): void {
        if (asset.setIndex === undefined) {
            throw new Error(`Asset set index is not set!`);
        }

        const updatedAsset: any = { ..._asset };
        if (updatedAsset[field] === undefined) {
            updatedAsset[field] = [];
        }
        updatedAsset[field] = updatedAsset[field].filter((item: any) => item !== value);
        setAsset(updatedAsset);

        _removeArrayValue(asset.setIndex, field, value);
    }

    //
    // Deletes the asset in question.
    //
    function deleteAsset(): void {
        if (asset.setIndex === undefined) {
            throw new Error(`Asset set index is not set!`);
        }

        _deleteAsset(asset.setIndex);
    }

    const value: IGalleryItemContext = {
        asset: _asset,
        setAsset,
        updateAsset,
        deleteAsset,
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

