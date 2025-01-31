import React, { createContext, ReactNode, useContext, useEffect, useState } from "react";
import { IGalleryItem } from "../lib/gallery-item";
import { useGallery } from "./gallery-context";

export interface IGalleryItemContext {

    //
    // The asset currently loaded.
    // 
    asset: IGalleryItem | undefined;

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

    //
    // Deletes the asset in question.
    //
    deleteAsset(): Promise<void>;
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
    assetId: string;
}

export function GalleryItemContextProvider({ children, assetId }: IProps) {

    const { updateGalleryItem, addArrayValue: _addArrayValue, removeArrayValue: _removeArrayValue, deleteAsset: _deleteAsset, getItemById  } = useGallery();

    //
    // The asset being edited.
    //
    const [_asset, setAsset] = useState<IGalleryItem | undefined>();

    useEffect(() => {
        if (_asset === undefined || _asset._id !== assetId) {
            const loadedAsset = getItemById(assetId);
            if (loadedAsset) {
                setAsset(loadedAsset);
            }
        } 
    }, [assetId])

    //
    // Updates the configuration of the asset.
    //
    async function updateAsset(assetUpdate: Partial<IGalleryItem>): Promise<void> {
        if (_asset === undefined) {
            throw new Error(`Asset ${assetId} not loaded!`);
        }

        setAsset({
            ..._asset,
            ...assetUpdate,
        });

        await updateGalleryItem(assetId, assetUpdate);
    }

    //
    // Adds an array value to the asset.
    //
    async function addArrayValue(field: string, value: any): Promise<void> {
        if (_asset === undefined) {
            throw new Error(`Asset ${assetId} not loaded!`);
        }

        const updatedAsset: any = { ..._asset };
        if (updatedAsset[field] === undefined) {
            updatedAsset[field] = [];
        }
        updatedAsset[field] = updatedAsset[field].filter((item: any) => item !== value);
        updatedAsset[field].push(value);
        setAsset(updatedAsset);

        await _addArrayValue(assetId, field, value);
    }

    //
    // Removes an array value from the asset.
    //
    async function removeArrayValue(field: string, value: any): Promise<void> {
        if (_asset === undefined) {
            throw new Error(`Asset ${assetId} not loaded!`);
        }

        const updatedAsset: any = { ..._asset };
        if (updatedAsset[field] === undefined) {
            updatedAsset[field] = [];
        }
        updatedAsset[field] = updatedAsset[field].filter((item: any) => item !== value);
        setAsset(updatedAsset);

        await _removeArrayValue(assetId, field, value);
    }

    //
    // Deletes the asset in question.
    //
    async function deleteAsset(): Promise<void> {
        await _deleteAsset(assetId);
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

