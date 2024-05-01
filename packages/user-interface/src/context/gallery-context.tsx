import React, { createContext, ReactNode, useContext, useEffect, useState } from "react";
import { IGalleryItem, ISelectedGalleryItem } from "../lib/gallery-item";
import { IGallerySource } from "./source/gallery-source";
import { useSearch } from "./search-context";
import { IAssetDetails, IGallerySink } from "./source/gallery-sink";
import { useApi } from "./api-context";
import dayjs from "dayjs";

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
    addAsset(assetDetails: IAssetDetails): Promise<string>;

    //
    // Updates an asset in the gallery by index.
    //
    updateAsset(assetIndex: number, asset: Partial<IGalleryItem>): Promise<void>;

    //
    // Loads data for an asset.
    //
    loadAsset(assetId: string, type: string, onLoaded: (objectURL: string) => void): void;

    //
    // Unloads data for an asset.
    //
    unloadAsset(assetId: string, type: string): void;

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
    async function addAsset(assetDetails: IAssetDetails): Promise<string> {
        if (!sink) {
            throw new Error(`Cannot edit readonly gallery.`); 
        }

        const assetId = await sink?.addAsset(assetDetails);

        const sortDate = assetDetails.photoDate || assetDetails.fileDate;
        const galleryItem: IGalleryItem = {
            _id: assetId,
            width: assetDetails.width,
            height: assetDetails.height,
            origFileName: assetDetails.fileName,
            hash: assetDetails.hash,
            location: assetDetails.location,
            fileDate: assetDetails.fileDate,
            photoDate: assetDetails.photoDate,
            sortDate,
            group: dayjs(sortDate).format("MMM, YYYY"),
            uploadDate: dayjs(new Date()).format(),
            properties: assetDetails.properties,
            labels: assetDetails.labels,
            description: "",
        };

        setAssets([ galleryItem, ...assets ]);

        return assetId;
    }

    //
    // Updates an asset in the gallery by index.
    //
    async function updateAsset(assetIndex: number, assetUpdate: Partial<IGalleryItem>): Promise<void> {
        if (!sink) {
            throw new Error(`Cannot edit readonly gallery.`); 
        }

        setAssets(prevAssets => {
            const newAsset = {
                ...prevAssets[assetIndex],
                ...assetUpdate,
            };
            return [
                ...prevAssets.slice(0, assetIndex),
                newAsset,
                ...prevAssets.slice(assetIndex + 1),
            ];
        });

        const assetId = assets[assetIndex]._id;
        await sink?.updateAsset(assetId, assetUpdate);
    }

    //
    // Loads data for an asset.
    //
    function loadAsset(assetId: string, type: string, onLoaded: (objectURL: string) => void): void {
        source.loadAsset(assetId, type, onLoaded);

    }

    //
    // Unloads data for an asset.
    //
    function unloadAsset(assetId: string, type: string): void {
        source.unloadAsset(assetId, type);
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

