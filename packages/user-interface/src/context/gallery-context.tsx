import React, { createContext, ReactNode, useContext, useEffect, useRef, useState } from "react";
import { IGalleryItem, ISelectedGalleryItem } from "../lib/gallery-item";
import { useDatabaseSync } from "./database-sync";
import flexsearch from "flexsearch";
import { IGallerySource } from "../lib/gallery-source";
import { IGallerySink } from "../lib/gallery-sink";
import { useApp } from "./app-context";

//
// Gets the sorting value from the gallery item.
//
export type SortFn = (galleryItem: IGalleryItem) => any;

export interface IGalleryContext {

    //
    // The assets currently loaded.
    //
    assets: IGalleryItem[];

    //
    // Adds an item to the the gallery.
    //
    addGalleryItem(galleryItem: IGalleryItem): Promise<void>;

    //
    // Updates an item in the gallery by index.
    //
    updateGalleryItem(galleryItemIndex: number, partialGalleryItem: Partial<IGalleryItem>): Promise<void>;

    //
    // Checks if an asset is already uploaded.
    //
    checkAssetHash(hash: string): Promise<boolean>;

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

    //
    // The current search text.
    //
    searchText: string;

    //
    // Search for assets based on text input.
    //
    search(searchText: string): Promise<void>;

    //
    // Clears the current search.
    //
    clearSearch(): Promise<void>;
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

    //
    // Sets the sorting function for the gallery.
    //
    sortFn?: SortFn;

    children: ReactNode | ReactNode[];
}

export function GalleryContextProvider({ source, sink, sortFn, children }: IGalleryContextProviderProps) {

    const { isInitialized } = useDatabaseSync();
    const { user } = useApp();

    //
    // Asset that have been loaded from storage.
    // These assets are unsorted.
    //
    const loadedAssets = useRef<Map<string, IGalleryItem>>(new Map<string, IGalleryItem>());

    //
    // Assets produced by the search and sorted.
    //
    const [ assets, setAssets ] = useState<IGalleryItem[]>([]);

    //
    // The item in the gallery that is currently selected.
    //
    const [selectedItem, setSelectedItem] = useState<ISelectedGalleryItem | undefined>(undefined);

    //
    // References the search index.
    //
    const searchIndexRef = useRef<flexsearch.Document<IGalleryItem, true>>(new flexsearch.Document<IGalleryItem, true>({
        preset: "memory",
        document: {
            id: "_", // Set when adding a document.
            index: [ "location", "description", "labels" ],
        },
    }));

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
    // The current search that has been executed.
    //
    const [ searchText, setSearchText ] = useState<string>("");

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
        if (user && isInitialized) {
            loadGallery();
        }
    }, [isInitialized, user]);

    //
    // Loads items into the gallery.
    //
    async function loadGallery(): Promise<void> {
        const galleryItems = await source.loadGalleryItems();
        for (const galleryItem of galleryItems) {
            loadedAssets.current.set(galleryItem._id, galleryItem);
            searchIndexRef.current.add(galleryItem._id, galleryItem);
        }

        // Renders the assets that we know about already.
        setAssets(applySort(galleryItems));
    }

    //
    // Adds an asset to the start of the gallery.
    //
    async function addGalleryItem(galleryItem: IGalleryItem): Promise<void> {
        if (!sink) {
            throw new Error(`Cannot edit readonly gallery.`); 
        }

        //
        // Add the asset for display in the UI.
        //
        loadedAssets.current.set(galleryItem._id, galleryItem);
        searchIndexRef.current.add(galleryItem._id, galleryItem);
        setAssets([ galleryItem, ...assets ]);

        await sink.addGalleryItem(galleryItem);
    }

    //
    // Updates an asset in the gallery by index.
    //
    async function updateGalleryItem(galleryItemIndex: number, partialGalleryItem: Partial<IGalleryItem>): Promise<void> {
        if (!sink) {
            throw new Error(`Cannot edit readonly gallery.`); 
        }

        //
        // Update assets in memory for display in the UI.
        //
        const assetId = assets[galleryItemIndex]._id;
        const updatedItem: IGalleryItem = { ...loadedAssets.current.get(assetId)!, ...partialGalleryItem };
        loadedAssets.current.set(assetId, updatedItem);
        searchIndexRef.current.add(assetId, updatedItem);
        setAssets([
            ...assets.slice(0, galleryItemIndex),
            updatedItem,
            ...assets.slice(galleryItemIndex + 1),
        ]);

        await sink.updateGalleryItem(assetId, partialGalleryItem);
    }

    //
    // Checks if an asset is already uploaded.
    //
    async function checkAssetHash(hash: string): Promise<boolean> {
        return await source.checkAssetHash(hash);
    }

    //
    // Uploads an asset.
    //
    async function uploadAsset(assetId: string, assetType: string, contentType: string, data: Blob): Promise<void> {
        if (!sink) {
            throw new Error(`Cannot upload to readonly gallery.`); 
        }

        await sink.storeAsset(assetId, assetType, {
            contentType, 
            data
        });
    }

    //
    // Loads data for an asset.
    //
    async function loadAsset(assetId: string, assetType: string): Promise<string | undefined> {
        const key = `${assetType}-${assetId}`;
        const existingCacheEntry = assetCache.current.get(key);
        if (existingCacheEntry) {
            existingCacheEntry.numRefs += 1;
            return existingCacheEntry.objectUrl;
        }

        const assetData = await source.loadAsset(assetId, assetType);
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
        const key = `${assetType}-${assetId}`;
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

    //
    // Sets the search text for finding assets.
    // Passing in empty string or undefined gets all assets.
    // This does a gallery reset when the search term has changed.
    //
    async function search(newSearchText: string): Promise<void> {
        
        console.log(`Setting asset search ${newSearchText}`);

        if (searchText === newSearchText) {
            //
            // No change.
            //
            return;
        }

        setAssets(applySort(searchAssets(newSearchText)));
        setSearchText(newSearchText);
    }

    //
    // Clears the current search.
    //
    async function clearSearch(): Promise<void> {
        await search("");
    }

    //
    // Sort all assets.
    //
    function applySort(items: IGalleryItem[]): IGalleryItem[] {
        const clone = items.slice();
        if (sortFn === undefined) {
            // No sort required.
            // We still clone it because the array must be different to trigger a render.
            return clone;
        }
        return clone.sort((a, b) => { // Warning: this mutates the array we just cloned.
            if (sortFn(a) < sortFn(b)) {
                return 1;
            }
            else if (a.sortDate > b.sortDate) {
                return -1;
            }
            else {
                return 0;
            }
        });
    }

    //
    // Search for assets based on text input.
    // 
    function searchAssets(searchText: string): IGalleryItem[] {
        if (searchText === "") {
            return Array.from(loadedAssets.current.values());
        }

        const searchResult = searchIndexRef.current.search(searchText);

        let searchedAssets: IGalleryItem[] = [];

        let searchedSet = new Set<string>();

        for (const searchTerm of searchResult) {
            for (const result of searchTerm.result) {
                const assetId = result as string;
                if (searchedSet.has(assetId)) {
                    // There search can return the same result multiple times.
                    // We don't want to include an asset more than once though.
                    continue;
                }

                searchedSet.add(assetId);
                searchedAssets.push(loadedAssets.current.get(assetId)!);
            }
        }        

        return searchedAssets
    }

    const value: IGalleryContext = {
        searchText,
        assets,
        addGalleryItem,
        updateGalleryItem,
        checkAssetHash,
        uploadAsset,
        loadAsset,
        unloadAsset,
        getPrev,
        getNext,
        selectedItem,
        setSelectedItem,
        clearSelectedItem,
        search,
        clearSearch,
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

