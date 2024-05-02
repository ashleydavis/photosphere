import React, { createContext, ReactNode, useContext, useEffect, useState } from "react";
import { IGalleryItem, ISelectedGalleryItem } from "../lib/gallery-item";
import { IGallerySource } from "./source/gallery-source";
import { useSearch } from "./search-context";
import { IGallerySink } from "./source/gallery-sink";
import { useApi } from "./api-context";
import dayjs from "dayjs";
import { IAsset } from "../def/asset";

export interface IGalleryContext {

    //
    // The assets currently loaded.
    //
    assets: IGalleryItem[];

    //
    // Loads assets into the gallery.
    //
    loadAssets(): Promise<void>;

    //
    // Adds an asset to the start of the gallery.
    //
    addAsset(asset: IGalleryItem): Promise<void>;

    //
    // Updates an asset in the gallery by index.
    //
    updateAsset(assetIndex: number, asset: Partial<IGalleryItem>): Promise<void>;

    //
    // Check that asset that has already been uploaded with a particular hash.
    //
    checkAsset(hash: string): Promise<string | undefined>;

    //
    // Uploads an asset.
    //
    uploadAsset(assetId: string, assetType: string, contentType: string, data: Blob): Promise<void>;

    //
    // Loads data for an asset.
    //
    loadAsset(assetId: string, assetType: string, onLoaded: (objectURL: string) => void): void;

    //
    // Unloads data for an asset.
    //
    unloadAsset(assetId: string, assetType: string): void;

    //
    // Gets the previous asset, or undefined if none.
    //
    getPrev(selectedItem: ISelectedGalleryItem): ISelectedGalleryItem | undefined;

    //
    // Gets the next asset, or undefined if none.
    //
    getNext(selectedItem: ISelectedGalleryItem): ISelectedGalleryItem | undefined;

    //
    // The currently selected gallery item or undefined when no item is selected.
    //
    selectedItem: ISelectedGalleryItem | undefined
    
    //
    // Sets the selected gallery item.
    //
    setSelectedItem(selectedItem: ISelectedGalleryItem | undefined): void;

    //
    // Clears the currently selected gallery item.
    //
    clearSelectedItem(): void;
}

const GalleryContext = createContext<IGalleryContext | undefined>(undefined);

export interface IGalleryContextProviderProps {

    //
    // The source that loads asset into the gallery.
    //
    source: IGallerySource;

    //
    // The sink that uploads and updates assets.
    //
    sink?: IGallerySink;

    children: ReactNode | ReactNode[];
}

export function GalleryContextProvider({ source, sink, children }: IGalleryContextProviderProps) {

    //
    // Interface to the backend.
    //
    const api = useApi();

    //
    // Assets that have been loaded from the backend.
    //
    const [ assets, setAssets ] = useState<IGalleryItem[]>([]);

    //
    // Gets search text.
    //
    const { searchText } = useSearch();

    //
    // The item in the gallery that is currently selected.
    //
    const [selectedItem, setSelectedItem] = useState<ISelectedGalleryItem | undefined>(undefined);

    //
    // Clears the selection when search text changes.
    //
    useEffect(() => {
        setSelectedItem(undefined);

    }, [searchText]);

    //
    // Resets the gallery when the search text changes.
    //
    useEffect(() => {
        if (api.isInitialised) {
            loadAssets();
        }
    }, [api.isInitialised]);

    //
    // Loads assets into the gallery.
    //
    async function loadAssets(): Promise<void> {
        const newAssets = await source.getAssets();
        setAssets(newAssets);
    }

    //
    // Adds an asset to the start of the gallery.
    //
    async function addAsset(galleryItem: IGalleryItem): Promise<void> {
        if (!sink) {
            throw new Error(`Cannot edit readonly gallery.`); 
        }

        await sink.addAsset(galleryItemToAsset(galleryItem));

        setAssets([ galleryItem, ...assets ]);
    }

    //
    // Converts a gallery item to an asset.
    //
    function galleryItemToAsset(galleryItem: IGalleryItem): IAsset {
        return {
            _id: galleryItem._id,
            width: galleryItem.width,
            height: galleryItem.height,
            origFileName: galleryItem.origFileName,
            hash: galleryItem.hash,
            location: galleryItem.location,
            fileDate: dayjs(galleryItem.fileDate).toDate(),
            photoDate: dayjs(galleryItem.photoDate).toDate(),
            sortDate: dayjs(galleryItem.sortDate).toDate(),
            uploadDate: dayjs().toDate(),
            properties: galleryItem.properties,
            labels: galleryItem.labels,
            description: galleryItem.description,
        };
    }

    //
    // Converts a partial gallery item to a partial asset.
    //
    function partialGalleryItemToAsset(partialGalleryItem: Partial<IGalleryItem>): Partial<IAsset> {
        return {
            width: partialGalleryItem.width,
            height: partialGalleryItem.height,
            origFileName: partialGalleryItem.origFileName,
            hash: partialGalleryItem.hash,
            location: partialGalleryItem.location,
            fileDate: partialGalleryItem.fileDate ? dayjs(partialGalleryItem.fileDate).toDate() : undefined,
            photoDate: partialGalleryItem.photoDate ? dayjs(partialGalleryItem.photoDate).toDate() : undefined,
            sortDate: partialGalleryItem.sortDate ? dayjs(partialGalleryItem.sortDate).toDate() : undefined,
            uploadDate: partialGalleryItem.uploadDate ? dayjs(partialGalleryItem.uploadDate).toDate() : undefined,
            properties: partialGalleryItem.properties,
            labels: partialGalleryItem.labels,
            description: partialGalleryItem.description,
        };
    }

    //
    // Updates an asset in the gallery by index.
    //
    async function updateAsset(assetIndex: number, assetUpdate: Partial<IGalleryItem>): Promise<void> {
        if (!sink) {
            throw new Error(`Cannot edit readonly gallery.`); 
        }

        setAssets(prevAssets => {
            const updatedGalleryItem = {
                ...prevAssets[assetIndex],
                ...assetUpdate,
            };
            return [
                ...prevAssets.slice(0, assetIndex),
                updatedGalleryItem,
                ...prevAssets.slice(assetIndex + 1),
            ];
        });

        const assetId = assets[assetIndex]._id;
        await sink.updateAsset(assetId, partialGalleryItemToAsset(assetUpdate));
    }

    //
    // Check that asset that has already been uploaded with a particular hash.
    //
    async function checkAsset(hash: string): Promise<string | undefined> {
        if (!sink) {
            throw new Error(`Cannot check asset in readonly gallery.`);
        }

        return await sink.checkAsset(hash);
    }    

    //
    // Uploads an asset.
    //
    async function uploadAsset(assetId: string, assetType: string, contentType: string, data: Blob): Promise<void> {
        if (!sink) {
            throw new Error(`Cannot upload to readonly gallery.`); 
        }

        await sink.uploadAsset(assetId, assetType, contentType, data);
    }

    //
    // Loads data for an asset.
    //
    function loadAsset(assetId: string, assetType: string, onLoaded: (objectURL: string) => void): void {
        source.loadAsset(assetId, assetType, onLoaded);

    }

    //
    // Unloads data for an asset.
    //
    function unloadAsset(assetId: string, assetType: string): void {
        source.unloadAsset(assetId, assetType);
    }

    //
    // Gets the previous asset, or undefined if none.
    //
    function getPrev(selectedItem: ISelectedGalleryItem): ISelectedGalleryItem | undefined {
        if (selectedItem.index < 0) {
            return undefined;
        }

        if (selectedItem.index > 0) {
            const prevIndex = selectedItem.index-1;
            return {
                item: assets[prevIndex],
                index: prevIndex,
            };
        }
        else {
            return undefined;
        }
    }

    //
    // Gets the next asset, or undefined if none.
    //
    function getNext(selectedItem: ISelectedGalleryItem): ISelectedGalleryItem | undefined {
        
        if (selectedItem.index < 0) {
            return undefined;
        }

        if (selectedItem.index < assets.length-1) {
            const nextIndex = selectedItem.index + 1;
            return {
                item: assets[nextIndex],
                index: nextIndex,
            };
        }
        else {
            return undefined;
        }
    }

    //
    // Clears the currently selected gallery item.
    //
    function clearSelectedItem(): void {
        setSelectedItem(undefined);
    }

    const value: IGalleryContext = {
        assets,
        loadAssets,
        addAsset,
        updateAsset,
        checkAsset, 
        uploadAsset,
        loadAsset,
        unloadAsset,
        getPrev,
        getNext,
        selectedItem,
        setSelectedItem,
        clearSelectedItem,
    };
    
    return (
        <GalleryContext.Provider value={value} >
            {children}
        </GalleryContext.Provider>
    );
}

//
// Use the gallery context in a component.
//
export function useGallery(): IGalleryContext {
    const context = useContext(GalleryContext);
    if (!context) {
        throw new Error(`Gallery context is not set! Add GalleryContextProvider to the component tree.`);
    }
    return context;
}

