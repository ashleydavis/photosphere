import React, { createContext, ReactNode, useContext, useEffect, useRef, useState } from "react";
import { IGalleryItem, ISelectedGalleryItem } from "../lib/gallery-item";
import flexsearch from "flexsearch";
import { useGallerySource } from "./gallery-source";

//
// Gets the sorting value from the gallery item.
//
export type SortFn = (galleryItem: IGalleryItem) => any;

export interface IAssetDataLoad {
    //
    // The object URL for the asset.
    //
    objectUrl: string;

    //
    // The source of the asset data.
    //
    source: "local" | "cloud";
}

export interface IGalleryContext {

    //
    // Set to true when the gallery is loading.
    //
    isLoading: boolean;

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
    loadAsset(assetId: string, assetType: string): Promise<IAssetDataLoad | undefined>;

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
    // Sets the sorting function for the gallery.
    //
    sortFn?: SortFn;

    children: ReactNode | ReactNode[];
}

export function GalleryContextProvider({ sortFn, children }: IGalleryContextProviderProps) {

    const { isLoading, assets, addAsset, updateAsset, checkAssetHash: _checkAssetHash, loadAsset: _loadAsset, storeAsset } = useGallerySource();

    //
    // Asset that have been loaded from storage.
    // These assets are unsorted.
    //
    const loadedAssets = useRef<Map<string, IGalleryItem>>(new Map<string, IGalleryItem>());

    //
    // Gallery items produced by the search and sorted.
    //
    const [ items, setItems ] = useState<IGalleryItem[]>([]);

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
        loadGallery();
    }, [assets]);

    //
    // Loads items into the gallery.
    //
    async function loadGallery(): Promise<void> {
        for (const asset of assets) {
            if (!loadedAssets.current.has(asset._id)) {
                loadedAssets.current.set(asset._id, asset);
                searchIndexRef.current.add(asset._id, asset);
            }
        }

        // Renders the assets that we know about already.
        setItems(applySort(assets));
    }

    //
    // Adds an asset to the start of the gallery.
    //
    async function addGalleryItem(galleryItem: IGalleryItem): Promise<void> {
        //
        // Add the asset for display in the UI.
        //
        loadedAssets.current.set(galleryItem._id, galleryItem);
        searchIndexRef.current.add(galleryItem._id, galleryItem);
        setItems([ galleryItem, ...items ]);

        addAsset(galleryItem);
    }

    //
    // Updates an asset in the gallery by index.
    //
    async function updateGalleryItem(galleryItemIndex: number, partialGalleryItem: Partial<IGalleryItem>): Promise<void> {
        //
        // Update assets in memory for display in the UI.
        //
        const assetId = items[galleryItemIndex]._id;
        const updatedItem: IGalleryItem = { ...loadedAssets.current.get(assetId)!, ...partialGalleryItem };
        loadedAssets.current.set(assetId, updatedItem);
        searchIndexRef.current.add(assetId, updatedItem);
        setItems([
            ...items.slice(0, galleryItemIndex),
            updatedItem,
            ...items.slice(galleryItemIndex + 1),
        ]);

        updateAsset(assetId, partialGalleryItem);
    }

    //
    // Checks if an asset is already uploaded.
    //
    async function checkAssetHash(hash: string): Promise<boolean> {
        return await _checkAssetHash(hash);
    }

    //
    // Uploads an asset.
    //
    async function uploadAsset(assetId: string, assetType: string, contentType: string, data: Blob): Promise<void> {
        await storeAsset(assetId, assetType, { 
            contentType, 
            data
        });
    }

    //
    // Loads data for an asset.
    //
    async function loadAsset(assetId: string, assetType: string): Promise<IAssetDataLoad | undefined> {
        const key = `${assetType}-${assetId}`;
        const existingCacheEntry = assetCache.current.get(key);
        if (existingCacheEntry) {
            existingCacheEntry.numRefs += 1;
            return {
                objectUrl: existingCacheEntry.objectUrl,
                source: "local",
            };
        }

        const assetData = await _loadAsset(assetId, assetType);
        if (!assetData) {
            return undefined;
        }

        const objectUrl = URL.createObjectURL(assetData.data);
        assetCache.current.set(key, { 
            numRefs: 1, 
            objectUrl, 
            contentType: assetData.contentType,
        });

        return {
            objectUrl,
            source: assetData.source
        };
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
                item: items[prevIndex],
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

        if (selectedItem.index < items.length-1) {
            const nextIndex = selectedItem.index + 1;
            return {
                item: items[nextIndex],
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

        setItems(applySort(searchAssets(newSearchText)));
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
        isLoading,
        searchText,
        assets: items,
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

