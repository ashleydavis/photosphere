import React, { createContext, ReactNode, useContext, useEffect, useRef, useState } from "react";
import { IGalleryItem } from "../lib/gallery-item";
import { useGallerySource } from "./gallery-source";
import { IObservable, ISubscription, Observable } from "../lib/subscription";

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
    // Gets all assets currently loaded in sorted order. 
    //
    getAllSortedItems(): IGalleryItem[];

    //
    // Gets the search for assets.
    //
    getSearchedItems(): IGalleryItem[];

    //
    // Subscribes to resets of the gallery.
    //
    onReset: IObservable<void>;

    //
    // Subscribes to new gallery items.
    //
    onNewItems: IObservable<IGalleryItem[]>;

    //
    // Adds an item to the the gallery.
    //
    addGalleryItem(galleryItem: IGalleryItem): void;

    //
    // Updates an item in the gallery by index.
    //
    updateGalleryItem(assetId: string, partialGalleryItem: Partial<IGalleryItem>): Promise<void>;

    //
    // Adds an array value to the asset.
    //
    addArrayValue(assetId: string, field: string, value: any): Promise<void>;

    //
    // Removes an array value from the asset.
    //
    removeArrayValue(assetId: string, field: string, value: any): Promise<void>;

    //
    // Deletes the asset.
    //
    deleteAsset(assetId: string): Promise<void>;

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
    selectedItems: Set<string>;

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
    children: ReactNode | ReactNode[];
}

export function GalleryContextProvider({ children }: IGalleryContextProviderProps) {

    const { isLoading, addAsset, updateAsset, updateAssets,
        onReset: __onReset,
        onNewItems: __onNewItems, 
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
    const loadedItems = useRef<Map<string, IGalleryItem>>(new Map<string, IGalleryItem>());

    //
    // List all loaded items before searching.
    //
    const allItems = useRef<IGalleryItem[]>([]);
   
    //
    // Items that are currently displayed in the gallery.
    //
    const searchedItems = useRef<IGalleryItem[]>([]);

    //
    // The item in the gallery that is currently selected.
    //
    const [selectedItemId, setSelectedItemId] = useState<string | undefined>(undefined);

    //
    // Multiple selected gallery items.
    //
    const [selectedItems, setSelectedItems] = useState<Set<string>>(new Set<string>());

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

    useEffect(() => {
        const subscription = __onReset.subscribe(_onReset);
        return () => {
            subscription.unsubscribe();            
        };
    }, []);

    useEffect(() => {
        const subscription = __onNewItems.subscribe(_onNewItems);
        return () => {
            subscription.unsubscribe();            
        };
    }, []);

    //
    // Gets all assets currently loaded in sorted order. 
    //
    function getAllSortedItems(): IGalleryItem[] {
        return allItems.current;
    }

    //
    // Gets the search for assets.
    //
    function getSearchedItems(): IGalleryItem[] {
        return searchedItems.current
    }

    //
    // Passes the gallery reset down the line to start incremetally loading assets.
    //
    const onReset = useRef<IObservable<void>>(new Observable<void>());

    //
    // Resets the gallery.
    //
    function _onReset(): void {
        allItems.current = [];
        searchedItems.current = [];
        setSelectedItems(new Set<string>());
        setSearchText("");

        onReset.current.invoke();
    }

    //
    // Passes newitems down the line as they are incrementally loaded.
    //
    const onNewItems = useRef<IObservable<IGalleryItem[]>>(new Observable<IGalleryItem[]>());

    //
    // Invokes subscriptions for new assets.
    //
    function _onNewItems(items: IGalleryItem[]) { 

        const newItems = removeDeletedAssets(items);
        allItems.current = allItems.current.concat(newItems);
        
 		for (const item of items) {
            loadedItems.current.set(item._id, item);
        }        

        const startSearchIndex = searchedItems.current.length;
        const newSearchedItems = applySearch(newItems, searchText, startSearchIndex);
        searchedItems.current = searchedItems.current.concat(newSearchedItems);

        onNewItems.current.invoke(newSearchedItems);
    };

    //
    // Adds an asset to the start of the gallery.
    //
    function addGalleryItem(galleryItem: IGalleryItem): void {
        addAsset(galleryItem);
    }

    //
    // Updates an asset in the gallery by index.
    //
    async function updateGalleryItem(assetId: string, partialGalleryItem: Partial<IGalleryItem>): Promise<void> {
        await updateAsset(assetId, partialGalleryItem);
    }

    //
    // Adds an array value to the asset.
    //  
    async function addArrayValue(assetId: string, field: string, value: any): Promise<void> {
        await _addArrayValue(assetId, field, value);
    }

    //
    // Removes an array value from the asset.
    //
    async function removeArrayValue(assetId: string, field: string, value: any): Promise<void> {
        await _removeArrayValue(assetId, field, value);
    }

    //
    // Deletes the asset.
    //
    async function deleteAsset(assetId: string): Promise<void> {
        await _deleteAssets([ assetId ]);
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
        if (loadedItems.current) {
            const asset = loadedItems.current.get(assetId);
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
            return searchedItems.current[prevIndex];
        }
        else {
            return undefined;
        }
    }

    //
    // Gets the next asset, or undefined if none.
    //
    function getNext(selectedItem: IGalleryItem): IGalleryItem | undefined {
        //todo: if I had a map of assetId to next assetId, I could just look it up without needing a search index.
        if (selectedItem.searchIndex === undefined) {
            throw new Error(`Selected item has no search index!`);
        }
        
        if (selectedItem.searchIndex < 0) {
            return undefined;
        }

        if (selectedItem.searchIndex < searchedItems.current.length-1) {
            const nextIndex = selectedItem.searchIndex + 1;
            return searchedItems.current[nextIndex];
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
        if (selectedItems.has(item._id)) {
            // Already selected.
            return;
        }
        setSelectedItems(new Set([...selectedItems, item._id]));        
    }

    //
    // Remove the item from the multiple selection.
    //
    function removeFromMultipleSelection(item: IGalleryItem): void {
        if (!selectedItems.has(item._id)) {
            // Already not selected.
            return;
        }

        const filtered =  [...selectedItems].filter(selectedItem => selectedItem !== item._id);
        setSelectedItems(new Set(filtered));
    }

    //
    // Clears the multiple selection.
    //
    function clearMultiSelection(): void {        
        setSelectedItems(new Set<string>());
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

        searchedItems.current = applySearch(allItems.current, newSearchText, 0);

        setSelectedItems(new Set<string>());
        setSearchText(newSearchText); // Triggers layout update.
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
    // Search for assets based on text input.
    // 
    function applySearch(items: IGalleryItem[], searchText: string, startSearchIndex: number): IGalleryItem[] {
        
        searchText = searchText.trim();

        if (searchText === "") {
            return items.map((item, index) => ({ ...item, searchIndex: startSearchIndex + index }));
        }

        const searchFields = [ "location", "description", "labels", "origFileName", "origPath", "contentType" ];
        const searchedItems: IGalleryItem[] = [];

        const searchLwr = searchText.toLowerCase();

        let searchIndex = startSearchIndex;

        for (const item of items) {
            for (const fieldName of searchFields) {
                const fieldValue = (item as any)[fieldName];
                if (fieldValue === undefined) {
                    continue;
                }

                if (fieldValue.toLowerCase().includes(searchLwr)) {
                    item.searchIndex = searchIndex;
                    searchedItems.push(item);
                    searchIndex += 1;                	
                    break;
                }                
            }
        }

        return searchedItems;
    }

    const value: IGalleryContext = {
        isLoading,
        searchText,
        getAllSortedItems,
        getSearchedItems,
        onReset: onReset.current,
        onNewItems: onNewItems.current,
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

