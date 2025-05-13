import React, { createContext, ReactNode, useContext, useEffect, useRef, useState } from "react";
import { IGalleryItem } from "../lib/gallery-item";
import { IItemsUpdate, useGallerySource } from "./gallery-source";
import { IObservable, Observable } from "../lib/subscription";
import dayjs from "dayjs";
import { isArray } from "lodash";

export interface IAssetDataLoad {
    //
    // The object URL for the asset.
    //
    objectUrl: string;
}

//
// Specifies how to sort the gallery.
//
interface ISortBy {
    //
    // Selects the field to sort by.
    //
    sortKey(asset: IGalleryItem): any;

    //
    // Gets the group of the asset.
    //
    group(asset: IGalleryItem): string[];

    //
    // Gets the heading for the group of the asset.
    //
    heading(group: string[]): string;
}

//
// Selects the sort type for the gallery.
//
const sortingMap: { [key: string]: ISortBy } = {
    date: {
        // Sorts the photos by date.
        sortKey: asset => asset.photoDate ? dayjs(asset.photoDate).toDate() : undefined,

        // Groups the photos by year and month.
        group: asset => asset.photoDate
            ? [
                dayjs(asset.photoDate).format("YYYY"),
                dayjs(asset.photoDate).format("MMMM"),
            ]
            : ["Undated"],

        // Formats the group heading.
        heading: (group: string[]) => group.slice().reverse().join(" "),
    },
    location: {
        // Sorts the photos by location.
        sortKey: asset => asset.location
            ? asset.location.split(",").map(s => s.trim()).reverse().slice(0, 3)
            : undefined,

        // Groups the photos by location
        group: asset => asset.location
            ? asset.location.split(",").map(s => s.trim()).reverse().slice(0, 3)
            : ["Location unknown"],

        // Formats the group heading.
        heading: (group: string[]) => group.slice().reverse().join(", "),
    },
}

export interface IGalleryContext {

    //
    // Set to true when the gallery is loading.
    //
    isLoading: boolean;

    //
    // Gets all assets currently loaded (unsorted).
    //
    allItems(): IGalleryItem[];

    //
    // Gets the searched items.
    //
    searchedItems(): IGalleryItem[];

    //
    // Gets the searched and sorted items.
    //
    sortedItems(): IGalleryItem[];

    //
    // Subscribes to resets of the gallery.
    //
    onReset: IObservable<void>;

    //
    // Subscribes to new gallery items.
    //
    onNewItems: IObservable<IGalleryItem[]>;

    //
    // Subscribes to items updated.
    //
    onItemsUpdated: IObservable<IItemsUpdate>;

    //
    // Subscribes to items deleted.
    //
    onItemsDeleted: IObservable<IItemsUpdate>;

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
    uploadAsset(assetId: string, assetType: string, assetData: Blob): Promise<void>;

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
    getPrev(item: IGalleryItem): IGalleryItem | undefined;

    //
    // Gets the next asset, or undefined if none.
    //
    getNext(item: IGalleryItem): IGalleryItem | undefined;

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
    // Set to true when the user is selecting multiple items.
    //
    isSelecting: boolean;

    //
    // Enables or disables selecting multiple items.
    //
    enableSelecting(selecting: boolean): void;

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

    //
    // The way the gallery is currenly sorted.
    //
    sortBy: string;

    //
    // Sets the way the gallery is sorted.
    //
    setSortBy(sortBy: string): void;

    //
    // Gets details of the current sort.
    //
    sorting(): ISortBy;
}

const GalleryContext = createContext<IGalleryContext | undefined>(undefined);

export interface IGalleryContextProviderProps {
    children: ReactNode | ReactNode[];
}

export function GalleryContextProvider({ children }: IGalleryContextProviderProps) {

    const { isLoading, addAsset, updateAsset,
        onReset: __onReset,
        onNewItems: __onNewItems,
        onItemsUpdated: __onItemsUpdated,
        onItemsDeleted: __onItemsDeleted,
        checkAssetHash: _checkAssetHash,
        loadAsset: _loadAsset, storeAsset,
        addArrayValue: _addArrayValue,
        removeArrayValue: _removeArrayValue,
        deleteAssets: _deleteAssets,
        getItemById: _getItemById,
    } = useGallerySource();

    //
    // List all loaded items before searching and sorting.
    //
    const allItems = useRef<IGalleryItem[]>([]);

    //
    // Items found by search (unsorted).
    //
    const searchedItems = useRef<IGalleryItem[]>([]);

    //
    // Sorted items displayed in the gallery.
    //
    const sortedItems = useRef<IGalleryItem[]>([]);

    //
    // The item in the gallery that is currently selected.
    //
    const [selectedItemId, setSelectedItemId] = useState<string | undefined>(undefined);

    //
    // Multiple selected gallery items.
    //
    const [selectedItems, setSelectedItems] = useState<Set<string>>(new Set<string>());

    //
    // Set to true when the user is selecting multiple items.
    //
    const [isSelecting, setIsSelecting] = useState<boolean>(false);

    //
    // A simple way to force state to update.
    //
    const [time, setTime] = useState<number>(0);

    //
    // The way the gallery is sorted.
    //
    const sortByRef = useRef<string>(localStorage.getItem("gallery-sort") || "date");

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
    }

    //
    // Caches loaded assets.
    //
    const assetCache = useRef<Map<string, IAssetCacheEntry>>(new Map<string, IAssetCacheEntry>());

    //
    // The current search that has been executed.
    //
    const [searchText, setSearchText] = useState<string>("");

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

    useEffect(() => {
        const subscription = __onItemsUpdated.subscribe(_onItemsUpdated);
        return () => {
            subscription.unsubscribe();            
        };
    }, []);

    useEffect(() => {
        const subscription = __onItemsDeleted.subscribe(_onItemsDeleted);
        return () => {
            subscription.unsubscribe();            
        };
    }, []);

    //
    // Gets all assets currently loaded (unsorted).
    //
    function _allItems(): IGalleryItem[] {
        return allItems.current;
    }

    //
    // Gets the searched items.
    //
    function _searchedItems(): IGalleryItem[] {
        return searchedItems.current
    }

    //
    // Gets the searched and sorted items.
    //
    function _sortedItems(): IGalleryItem[] {
        return sortedItems.current
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

        const newSearchedItems = applySearch(newItems, searchText);
        searchedItems.current = searchedItems.current.concat(newSearchedItems);
        const sorting = sortingMap[sortByRef.current];
        if (!sorting) {
            throw new Error(`Unknown sorting value: ${sortByRef.current}`);
        }

        sortedItems.current = applySort(searchedItems.current, sorting);

        onNewItems.current.invoke(newSearchedItems);
    };

    //
    // Subscribes to items updates.
    //
    const onItemsUpdated = useRef<IObservable<IItemsUpdate>>(new Observable<IItemsUpdate>());

    //
    // Invokes subscriptions for updated items.
    //
    function _onItemsUpdated(itemUpdated: IItemsUpdate) { 
        onItemsUpdated.current.invoke(itemUpdated);
    }

    //
    // Subscribes to item deletions.
    //
    const onItemsDeleted = useRef<IObservable<IItemsUpdate>>(new Observable<IItemsUpdate>());

    //
    // Removes gallery items from the array that have been deleted.
    //
    function removeItemsFromArray(items: IGalleryItem[], assetIds: string[]): IGalleryItem[] {
        return items.filter(item => !assetIds.includes(item._id));
    }

    //
    // Invokes subscriptions for item deletions.
    //
    function _onItemsDeleted(itemsRemoved: IItemsUpdate) { 
        allItems.current = removeItemsFromArray(allItems.current, itemsRemoved.assetIds);
        searchedItems.current = removeItemsFromArray(searchedItems.current, itemsRemoved.assetIds);
        sortedItems.current = removeItemsFromArray(sortedItems.current, itemsRemoved.assetIds);

        onItemsDeleted.current.invoke(itemsRemoved);
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
    async function uploadAsset(assetId: string, assetType: string, assetData: Blob): Promise<void> {
        await storeAsset(assetId, assetType, assetData);
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
            };
        }

        const assetData = await _loadAsset(assetId, assetType);
        if (!assetData) {
            return undefined;
        }

        const objectUrl = URL.createObjectURL(assetData);
        assetCache.current.set(key, { 
            numRefs: 1, 
            objectUrl, 
        });

        return {
            objectUrl,
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
        return _getItemById(assetId);
    }

    //
    // Gets the previous asset, or undefined if none.
    //
    function getPrev(item: IGalleryItem): IGalleryItem | undefined {
        const itemIndex = sortedItems.current.findIndex(i => i._id === item._id);
        if (itemIndex <= 0) {
            return undefined;
        }
        return sortedItems.current[itemIndex - 1];
    }

    //
    // Gets the next asset, or undefined if none.
    //
    function getNext(item: IGalleryItem): IGalleryItem | undefined {
        const itemIndex = sortedItems.current.findIndex(i => i._id === item._id);
        if (itemIndex < 0 || itemIndex >= sortedItems.current.length - 1) {
            return undefined;
        }
        return sortedItems.current[itemIndex + 1];
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

        const filtered = [...selectedItems].filter(selectedItem => selectedItem !== item._id);
        setSelectedItems(new Set(filtered));

        if (filtered.length === 0) {
            setIsSelecting(false);
        }
    }

    //
    // Clears the multiple selection.
    //
    function clearMultiSelection(): void {        
        setIsSelecting(false);
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

        searchedItems.current = applySearch(allItems.current, newSearchText);

        const sorting = sortingMap[sortByRef.current];
        if (!sorting) {
            throw new Error(`Unknown sorting value: ${sortByRef.current}`);
        }

        sortedItems.current = applySort(searchedItems.current, sorting);

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
    // Determine if a field value matches the search text.
    //
    function valueMatches(fieldValue: any, searchTextLwr: string): boolean {
        if (Array.isArray(fieldValue)) {
            for (const elementValue of fieldValue) {
                if (elementValue.toLowerCase().includes(searchTextLwr)) {
                    return true;
                }
            }
            return false;
        }
        else {
            return fieldValue.toLowerCase().includes(searchTextLwr);
        }
    }

    //
    // Searches for a term in fields of assets.
    //
    function applySearchTerm(searchText: string, items: IGalleryItem[], searchFields: string[]) {
        const searchedItems: IGalleryItem[] = [];
        const searchTextLwr = searchText.toLowerCase();

        searchFields = searchFields.map(field => field.toLowerCase());

        for (const item of items) {

            let matches = false;

            for (const searchedFieldName of searchFields) {
                //
                // Find the lower case field name in the item.
                //
                for (const [actualFieldName, fieldValue] of Object.entries(item)) {
                    if (actualFieldName.toLowerCase().includes(searchedFieldName)) {
                        if (valueMatches(fieldValue, searchTextLwr)) {
                            matches = true;
                            break;
                        }
                    }
                }

                if (matches) {
                    break;
                }
            }

            if (matches) {
                searchedItems.push(item);
            }
        }

        return searchedItems;
    }

    const defaultSearchFields = [ "_id", "hash", "location", "description", "labels", "origFileName", "origPath", "contentType" ];

    //
    // Search for assets based on text input.
    // 
    function applySearch(items: IGalleryItem[], searchText: string): IGalleryItem[] {
        
        searchText = searchText.trim();

        if (searchText === "") {
            return items.slice(); // Clone the array to make sure state update triggers a render.
        }

        const terms = searchText.split(' ').map(term => term.trim());

        let searchFields = defaultSearchFields;

        for (let term of terms) {
            if (term.startsWith(".")) {
                term = term.substring(1);
                const parts = term.split("=").map(part => part.trim());
                if (parts.length !== 2) {
                    continue; // Bad formatting.
                }
                searchFields = [ parts[0] ];
                term = parts[1];
            }

            items = applySearchTerm(term, items, searchFields);
        }
        
        return items;
    }

    //
    // Sorts the items in the gallery.
    //
    function applySort(items: IGalleryItem[], sorting: ISortBy): IGalleryItem[] {
        const sortedItems = items.slice();
        sortedItems.sort((a, b) => {
            const sortA = sorting.sortKey(a);
            const sortB = sorting.sortKey(b);
            if (sortA === undefined) {
                if (sortB === undefined) {
                    return 0; // Equal.
                }
                else {
                    return 1; // a has no sort value, so it comes last.
                }
            }
            else if (sortB === undefined) {
                return -1; // b has no sort value, so it comes last.
            }

            if (isArray(sortA) && isArray(sortB)) {
                for (let i = 0; i < Math.min(sortA.length, sortB.length); i++) {
                    if (sortA[i] < sortB[i]) {
                        return -1; // a comes before b
                    }

                    if (sortA[i] > sortB[i]) {
                        return 1;  // a comes after b
                    }
                }

                // If all compared elements are equal, sort by length
                return sortA.length - sortB.length;
            }
            else {
                if (sortA < sortB) {
                    return 1; // a comes after b.
                }
                else if (sortA > sortB) {
                    return -1; // a comes before b.
                }
                else {
                    return 0; // a and b are equal.
                }
            }
        });

        return sortedItems;
    }

    //
    // Sets the method for sorting the gallery.
    //
    function setSortBy(sortBy: string): void {
        const sorting = sortingMap[sortBy];
        if (!sorting) {
            throw new Error(`Unknown sorting value: ${sortBy}`);
        }

        sortedItems.current = applySort(searchedItems.current, sorting);

        sortByRef.current = sortBy;
        setTime(Date.now());

        localStorage.setItem("gallery-sort", sortBy);
    }

    const value: IGalleryContext = {
        isLoading,
        searchText,
        allItems: _allItems,
        searchedItems: _searchedItems,
        sortedItems: _sortedItems,
        onReset: onReset.current,
        onNewItems: onNewItems.current,
        onItemsUpdated: onItemsUpdated.current,
        onItemsDeleted: onItemsDeleted.current,
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
        isSelecting,
        enableSelecting: setIsSelecting,
        addToMultipleSelection,
        removeFromMultipleSelection,
        clearMultiSelection,
        search,
        clearSearch,
        sortBy: sortByRef.current,
        setSortBy,
        sorting: () => sortingMap[sortByRef.current],
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

