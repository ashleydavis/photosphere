import React, { createContext, ReactNode, useContext, useEffect, useRef, useState } from "react";
import { IGalleryItem } from "../lib/gallery-item";
import flexsearch from "flexsearch";
import { useGallerySource } from "./gallery-source";
import { update } from "lodash";

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
    items: IGalleryItem[];

    //
    // Adds an item to the the gallery.
    //
    addGalleryItem(galleryItem: IGalleryItem): void;

    //
    // Updates an item in the gallery by index.
    //
    updateGalleryItem(assetId: string, partialGalleryItem: Partial<IGalleryItem>): void;

    //
    // Adds an array value to the asset.
    //
    addArrayValue(assetId: string, field: string, value: any): void;

    //
    // Removes an array value from the asset.
    //
    removeArrayValue(assetId: string, field: string, value: any): void;

    //
    // Deletes the asset.
    //
    deleteAsset(assetId: string): void;

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
    // Gets a gallery item by id.
    //
    getItemById(assetId: string): IGalleryItem | undefined;

    //
    // Gets the previous asset, or undefined if none.
    //
    getPrev(selectedItem: IGalleryItem): IGalleryItem | undefined;

    //
    // Gets the next asset, or undefined if none.
    //
    getNext(selectedItem: IGalleryItem): IGalleryItem | undefined;

    //
    // The currently selected gallery item or undefined when no item is selected.
    //
    selectedItemId: string | undefined
    
    //
    // Sets the selected gallery item.
    //
    setSelectedItemId(selectedItemId: string | undefined): void;

    //
    // Clears the currently selected gallery item.
    //
    clearSelectedItem(): void;

    //
    // Multiple selected gallery items.
    //
    selectedItems: IGalleryItem[];

    //
    // Add the item to the multiple selection.
    //
    addToMultipleSelection(item: IGalleryItem): void;

    //
    // Remove the item from the multiple selection.
    //
    removeFromMultipleSelection(item: IGalleryItem): void;

    //
    // Clears the multiple selection.
    //
    clearMultiSelection(): void;

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

    const { isLoading, assets, addAsset, updateAsset, updateAssets,
        checkAssetHash: _checkAssetHash, 
        loadAsset: _loadAsset, storeAsset,
        addArrayValue: _addArrayValue,
        removeArrayValue: _removeArrayValue,
        deleteAssets: _deleteAssets,
        } = useGallerySource();

    //
    // Asset that have been loaded from storage.
    // These assets are unsorted.
    //
    const loadedAssets = useRef<Map<string, IGalleryItem>>();

    //
    // Gallery items produced by the search and sorted.
    //
    const [ items, setItems ] = useState<IGalleryItem[]>([]);

    //
    // The item in the gallery that is currently selected.
    //
    const [selectedItemId, setSelectedItemId] = useState<string | undefined>(undefined);

    //
    // Multiple selected gallery items.
    //
    const [selectedItems, setSelectedItems] = useState<IGalleryItem[]>([]);

    //
    // References the search index.
    //
    const searchIndexRef = useRef<flexsearch.Document<IGalleryItem, true>>();

    //
    // Maps by id to searched assets.
    //
    const searchedAssets = useRef<Map<string, IGalleryItem>>();

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
        setSelectedItemId(undefined);
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
        loadedAssets.current = new Map<string, IGalleryItem>();
        searchIndexRef.current = new flexsearch.Document<IGalleryItem, true>({
            preset: "memory",
            document: {
                id: "_", // Set when adding a document.
                index: [ "location", "description", "labels" ],
            },
        });

        const _assets = Object.values(assets);

        for (const asset of _assets) {
            loadedAssets.current.set(asset._id, asset);
            searchIndexRef.current.add(asset._id, asset);
        }

        // Renders the assets that we know about already.
        const items = applySort(removeDeletedAssets(_assets));
        setItems(items);
        setSelectedItems(items.filter(item => item.selected));
    }

    //
    // Adds an asset to the start of the gallery.
    //
    function addGalleryItem(galleryItem: IGalleryItem): void {
        addAsset(galleryItem);
    }

    //
    // Updates an asset in the gallery by index.
    //
    function updateGalleryItem(assetId: string, partialGalleryItem: Partial<IGalleryItem>): void {
        updateAsset(assetId, partialGalleryItem);
    }

    //
    // Adds an array value to the asset.
    //
    function addArrayValue(assetId: string, field: string, value: any): void {
        _addArrayValue(assetId, field, value);
    }

    //
    // Removes an array value from the asset.
    //
    function removeArrayValue(assetId: string, field: string, value: any): void {
        _removeArrayValue(assetId, field, value);
    }

    //
    // Deletes the asset.
    //
    function deleteAsset(assetId: string): void {
        _deleteAssets([ assetId ]);
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
    // Gets a gallery item by id.
    //
    function getItemById(assetId: string): IGalleryItem | undefined {
        if (searchedAssets.current) {
            const asset = searchedAssets.current.get(assetId);
            if (asset) {
                return asset;
            }
        }

        if (loadedAssets.current) {
            const asset = loadedAssets.current.get(assetId);
            if (asset) {
                return asset;
            }
        }

        return undefined;        
    }

    //
    // Gets the previous asset, or undefined if none.
    //
    function getPrev(selectedItem: IGalleryItem): IGalleryItem | undefined {
        if (selectedItem.searchIndex === undefined) {
            throw new Error(`Selected item has no search index!`);
        }

        if (selectedItem.searchIndex < 0) {
            return undefined;
        }

        if (selectedItem.searchIndex > 0) {
            const prevIndex = selectedItem.searchIndex-1;
            return items[prevIndex];
        }
        else {
            return undefined;
        }
    }

    //
    // Gets the next asset, or undefined if none.
    //
    function getNext(selectedItem: IGalleryItem): IGalleryItem | undefined {
        if (selectedItem.searchIndex === undefined) {
            throw new Error(`Selected item has no search index!`);
        }
        
        if (selectedItem.searchIndex < 0) {
            return undefined;
        }

        if (selectedItem.searchIndex < items.length-1) {
            const nextIndex = selectedItem.searchIndex + 1;
            return items[nextIndex];
        }
        else {
            return undefined;
        }
    }

    //
    // Clears the currently selected gallery item.
    //
    function clearSelectedItem(): void {
        setSelectedItemId(undefined);
    }

    //
    // Add the item to the multiple selection.
    //
    function addToMultipleSelection(item: IGalleryItem): void {
        if (item.selected) {
            // Already selected.
            return;
        }
        setSelectedItems([...selectedItems, item]);
        updateAssets([{ assetId: item._id, partialAsset: { selected: true } }]);
    }

    //
    // Remove the item from the multiple selection.
    //
    function removeFromMultipleSelection(item: IGalleryItem): void {
        if (!item.selected) {
            // Already not selected.
            return;
        }

        setSelectedItems(selectedItems.filter(selectedItem => selectedItem._id !== item._id));        
        updateAssets([{ assetId: item._id, partialAsset: { selected: false } }]);
    }

    //
    // Clears the multiple selection.
    //
    function clearMultiSelection(): void {        
        updateAssets(selectedItems.map(item => ({ 
            assetId: item._id, 
            partialAsset: { selected: false },
        })));
        setSelectedItems([]);
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

        const items = applySort(removeDeletedAssets(searchAssets(newSearchText)));
        setItems(items);
        setSelectedItems(items.filter(item => item.selected));
        setSearchText(newSearchText);
    }

    //
    // Clears the current search.
    //
    async function clearSearch(): Promise<void> {
        await search("");
    }

    //
    // Removes deleted assets.
    // This is a simple way to mark assets as deleted but not remove them from the database.
    //
    function removeDeletedAssets(items: IGalleryItem[]): IGalleryItem[] {
        return items.filter(item => !item.deleted);
    }

    //
    // Sort all assets.
    //
    function applySort(items: IGalleryItem[]): IGalleryItem[] {
        const sorted = items.slice();
        if (sortFn !== undefined) {
            sorted.sort((a, b) => { // Warning: this mutates the array we just cloned.
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
        else {
            // No sort required.
            // We still clone it because the array must be different to trigger a render.
        }

        //
        // Bake in the search index now that we have sorted the assets.
        //
        const searched =  sorted.map((asset, index) => ({ ...asset, searchIndex: index }));

        searchedAssets.current = new Map<string, IGalleryItem>();
        for (const asset of searched) {
            searchedAssets.current.set(asset._id, asset);
        }
        
        return searched;
    }

    //
    // Search for assets based on text input.
    // 
    function searchAssets(searchText: string): IGalleryItem[] {
        if (searchText === "") {
            return Object.values(assets);
        }

        const searchResult = searchIndexRef.current!.search(searchText, 1_000_000);

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
                searchedAssets.push(loadedAssets.current!.get(assetId)!);
            }
        }        

        return searchedAssets
    }

    const value: IGalleryContext = {
        isLoading,
        searchText,
        items,
        addGalleryItem,
        updateGalleryItem,
        addArrayValue,
        removeArrayValue,
        deleteAsset,
        checkAssetHash,
        uploadAsset,
        loadAsset,
        unloadAsset,
        getItemById,
        getPrev,
        getNext,
        selectedItemId,
        setSelectedItemId,
        clearSelectedItem,
        selectedItems,
        addToMultipleSelection,
        removeFromMultipleSelection,
        clearMultiSelection,
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

