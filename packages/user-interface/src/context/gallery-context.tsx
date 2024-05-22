import React, { createContext, ReactNode, useContext, useEffect, useRef, useState } from "react";
import { IGalleryItem, ISelectedGalleryItem } from "../lib/gallery-item";
import dayjs from "dayjs";
import { useDatabaseSync } from "./database-sync";
import flexsearch from "flexsearch";
import { IAsset, IAssetSink, IAssetSource, IDatabase, IDatabases, IHashRecord, IPage } from "database";

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
    // Gets the assets already uploaded with a particular hash.
    //
    checkAssets(hash: string): Promise<string[] | undefined>;

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
    source: IAssetSource;

    //
    // The sink that uploads and updates assets.
    //
    sink?: IAssetSink;

    //
    // The database that contains asset metadata.
    //
    databases: IDatabases;

    children: ReactNode | ReactNode[];
}

export function GalleryContextProvider({ source, sink, databases, children }: IGalleryContextProviderProps) {

    // 
    // Interface to database sync.
    //
    const { isInitialized, user } = useDatabaseSync();

    //
    // The collection currently being viewed.
    //
    const [ collectionId, setCollectionId ] = useState<string | undefined>(undefined);

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
        if (user && isInitialized && source.isInitialised) {
            loadAssets();
        }
    }, [isInitialized, source.isInitialised, user]);

    //
    // Loads assets into the gallery.
    //
    async function loadAssets(): Promise<void> {
        let _collectionId = collectionId;
        if (_collectionId === undefined) {
            if (user === undefined) {
                throw new Error(`Expected to know the user when loading assets.`);
            }
            
            _collectionId = user.collections.default;
            setCollectionId(_collectionId);
        }

        console.log(`Have collection id ${_collectionId}`); //fio:

        const galleryItems: IGalleryItem[] = [];
        const metadataCollection = databases.database(_collectionId).collection<IAsset>("metadata");
        let next: string | undefined = undefined;
        while (true) {
            const page: IPage<IAsset> = await metadataCollection.getAll(1000, next);
            next = page.next;
            for (const asset of page.records) {
                const item = assetToGalleryItem(asset);
                loadedAssets.current.set(item._id, item);
                searchIndexRef.current.add(item._id, item);
                galleryItems.push(item);
            }

            if (next === undefined) {
                break; // No more metadata.
            }
        }

        setAssets(applySort(galleryItems));
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
        loadedAssets.current.set(galleryItem._id, galleryItem);
        searchIndexRef.current.add(galleryItem._id, galleryItem);
        setAssets([ galleryItem, ...assets ]);

        //
        // Add the asset to the database.
        //
        await databases.submitOperations([
            {
                databaseName: collectionId,
                collectionName: "metadata",
                recordId: galleryItem._id,
                op: {
                    type: "set",
                    fields: galleryItemToAsset(galleryItem),
                },
            },
            {
                databaseName: collectionId,
                collectionName: "hashes",
                recordId: galleryItem.hash,
                op: {
                    type: "push",
                    field: "assetIds",
                    value: galleryItem._id,
                },
            }
        ]);
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
            throw new Error(`Cannot edit asset without a collection id.`);
        }

        //
        // Update assets in memory for display in the UI.
        //
        const assetId = assets[assetIndex]._id;
        const updatedItem: IGalleryItem = { ...loadedAssets.current.get(assetId)!, ...assetUpdate };
        loadedAssets.current.set(assetId, updatedItem);
        searchIndexRef.current.add(assetId, updatedItem);
        setAssets([
            ...assets.slice(0, assetIndex),
            updatedItem,
            ...assets.slice(assetIndex + 1),
        ]);

        //
        // Update the asset in the database.
        //
        await databases.submitOperations([{
            databaseName: collectionId,
            collectionName: "metadata",
            recordId: assetId,
            op: {
                type: "set",
                fields: partialGalleryItemToAsset(assetUpdate),
            },
        }]);
    }

    //
    // Gets the assets already uploaded with a particular hash.
    //
    async function checkAssets(hash: string): Promise<string[] | undefined> {
        if (!collectionId) {
            throw new Error(`Cannot check asset without a collection id.`);
        }

        const assetCollection = databases.database(collectionId);
        const hashRecord = await assetCollection.collection<IHashRecord>("hashes").getOne(hash);
        if (!hashRecord) {
            return undefined;
        }

        if (hashRecord.assetIds.length < 1) { 
            return undefined;
        }

        return hashRecord.assetIds;
    }    

    //
    // Uploads an asset.
    //
    async function uploadAsset(assetId: string, assetType: string, contentType: string, data: Blob): Promise<void> {
        if (!sink) {
            throw new Error(`Cannot upload to readonly gallery.`); 
        }

        if (!collectionId) {
            throw new Error(`Cannot upload asset without a collection id.`);
        }

        await sink.storeAsset(collectionId, assetId, assetType, {
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
        return items.sort((a, b) => { // Warning: this mutates the array. Should be ok.
            if (a.sortDate < b.sortDate) {
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
        loadAssets,
        addAsset,
        updateAsset,
        checkAssets, 
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

