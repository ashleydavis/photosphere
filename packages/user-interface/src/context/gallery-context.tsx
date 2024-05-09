import React, { createContext, ReactNode, useContext, useEffect, useRef, useState } from "react";
import { IGalleryItem, ISelectedGalleryItem } from "../lib/gallery-item";
import { IGallerySource } from "./source/gallery-source";
import { useSearch } from "./search-context";
import { IGallerySink } from "./source/gallery-sink";
import dayjs from "dayjs";
import { IAsset } from "../def/asset";
import { useDatabaseSync } from "./database-sync";

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
    loadAsset(assetId: string, assetType: string): Promise<string | undefined>;

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
    // Gets search text.
    //
    const { searchText } = useSearch();

    // 
    // Interface to database sync.
    //
    const { isInitialized } = useDatabaseSync();

    //
    // The collection currently being viewed.
    //
    const [ collectionId, setCollectionId ] = useState<string | undefined>(undefined);

    //
    // Assets that have been loaded from the backend.
    //
    const [ assets, setAssets ] = useState<IGalleryItem[]>([]);

    //
    // The item in the gallery that is currently selected.
    //
    const [selectedItem, setSelectedItem] = useState<ISelectedGalleryItem | undefined>(undefined);

    //
    // A cache entry for a loaded asset.
    //
    interface IAssetCacheEntry {
        //
        // Number of references to this asset.
        //
        numRefs: number;

        //
        // Object URL for the asset.
        //
        objectUrl: string;

        //
        // The content type for the asset.
        //
        contentType: string;
    }

    //
    // Caches loaded assets.
    //
    const assetCache = useRef<Map<string, IAssetCacheEntry>>(new Map<string, IAssetCacheEntry>());

    //
    // Clears the selection when search text changes.
    //
    useEffect(() => {
        setSelectedItem(undefined);

    }, [searchText]);

    //
    // Loads assets on mount.
    //
    useEffect(() => {
        if (isInitialized && source.isInitialised) {
            loadAssets();
        }
    }, [isInitialized, source.isInitialised]);

    //
    // Loads assets into the gallery.
    //
    async function loadAssets(): Promise<void> {
        let _collectionId = collectionId;
        if (_collectionId === undefined) {
            const user = await source.getUser();
            if (user === undefined) {
                return;
            }
            
            _collectionId = user.collections.default;
            setCollectionId(_collectionId);
        }

        const newAssets = await source.getAssets(_collectionId);
        const galleryItems = newAssets.map(assetToGalleryItem);
        setAssets(galleryItems);
    }

    //
    // Adds an asset to the start of the gallery.
    //
    async function addAsset(galleryItem: IGalleryItem): Promise<void> {
        if (!sink) {
            throw new Error(`Cannot edit readonly gallery.`); 
        }

        if (!collectionId) {
            throw new Error(`Cannot add asset without a collection id.`);
        }

        //
        // Add the asset for display in the UI.
        //
        setAssets([ galleryItem, ...assets ]);

        //
        // Add the asset to the database.
        //
        await sink.submitOperations({
            id: collectionId,
            ops: [{
                id: galleryItem._id,
                ops: [{
                    type: "set",
                    fields: galleryItem,
                }]
            }],
        });

    }

    //
    // Converts an asset to a gallery item.
    //
    function assetToGalleryItem(asset: IAsset): IGalleryItem {
        return {
            ...asset,
            group: dayjs(asset.sortDate).format("MMM, YYYY"),
        };
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
            fileDate: galleryItem.fileDate,
            photoDate: galleryItem.photoDate,
            sortDate: galleryItem.sortDate,
            uploadDate: dayjs().toISOString(),
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
            fileDate: partialGalleryItem.fileDate,
            photoDate: partialGalleryItem.photoDate,
            sortDate: partialGalleryItem.sortDate,
            uploadDate: partialGalleryItem.uploadDate,
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

        if (!collectionId) {
            throw new Error(`Cannot add asset without a collection id.`);
        }

        //
        // Update assets in memory for display in the UI.
        //
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

        //
        // Update the asset in the database.
        //
        const assetId = assets[assetIndex]._id;

        await sink.submitOperations({
            id: collectionId,
            ops: [{
                id: assetId,
                ops: [{
                    type: "set",
                    fields: partialGalleryItemToAsset(assetUpdate),
                }]
            }],
        });
    }

    //
    // Check that asset that has already been uploaded with a particular hash.
    //
    async function checkAsset(hash: string): Promise<string | undefined> {
        if (!sink) {
            throw new Error(`Cannot check asset in readonly gallery.`);
        }

        if (!collectionId) {
            throw new Error(`Cannot add asset without a collection id.`);
        }

        return await sink.checkAsset(collectionId, hash);
    }    

    //
    // Uploads an asset.
    //
    async function uploadAsset(assetId: string, assetType: string, contentType: string, data: Blob): Promise<void> {
        if (!sink) {
            throw new Error(`Cannot upload to readonly gallery.`); 
        }

        if (!collectionId) {
            throw new Error(`Cannot add asset without a collection id.`);
        }

        await sink.storeAsset(collectionId, assetType, {
            _id: assetId, 
            contentType, 
            data
        });
    }

    //
    // Loads data for an asset.
    //
    async function loadAsset(assetId: string, assetType: string): Promise<string | undefined> {
        if (!collectionId) {
            throw new Error(`Cannot load asset without a collection id.`);
        }

        const key = `${collectionId}-${assetType}-${assetId}`;
        const existingCacheEntry = assetCache.current.get(key);
        if (existingCacheEntry) {
            existingCacheEntry.numRefs += 1;
            return existingCacheEntry.objectUrl;
        }

        const assetData = await source.loadAsset(collectionId, assetId, assetType);
        if (!assetData) {
            return undefined;
        }

        const objectUrl = URL.createObjectURL(assetData.data);
        assetCache.current.set(key, { 
            numRefs: 1, 
            objectUrl, 
            contentType: assetData.contentType,
        });
        return objectUrl;
    }

    //
    // Unloads data for an asset.
    //
    function unloadAsset(assetId: string, assetType: string): void {
        if (!collectionId) {
            throw new Error(`Cannot unload asset without a collection id.`);
        }

        const key = `${collectionId}-${assetType}-${assetId}`;
        const cacheEntry = assetCache.current.get(key);
        if (cacheEntry) {
            if (cacheEntry.numRefs === 1) {
                URL.revokeObjectURL(cacheEntry.objectUrl);
                assetCache.current.delete(key);
            }
            else {
                cacheEntry.numRefs -= 1;
            }
        }
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

