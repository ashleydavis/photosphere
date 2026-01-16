import React, { ReactNode, createContext, useContext, useEffect, useRef, useState } from "react";
import { IGalleryItem } from "../lib/gallery-item";
import { GallerySourceContext, IItemsUpdate, IGalleryItemMap, IGallerySource } from "./gallery-source";
import { IAsset, IDatabaseOp } from "defs";
import dayjs from "dayjs";
import { RandomUuidGenerator } from "utils";
import { IObservable, Observable } from "../lib/subscription";
import { loadAssets as loadAssetsApi } from "api/src/lib/load-assets";
import axios from "axios";
import { TaskStatus } from "task-queue";
import type { ILoadAssetsData, ILoadAssetsResult, IAssetPageMessage } from "api/src/lib/load-assets.types";
import type { ITaskQueueProvider } from "task-queue";
import { usePlatform } from "./platform-context";

//
// Adds "asset database" specific functionality to the gallery source.
//
export interface IAssetDatabase extends IGallerySource {
    //
    // The currently viewed database.
    //
    databaseId: string | undefined;

    //
    // Sets the viewed database.
    //
    setDatabaseId(databaseId: string): void;

    //
    // Moves assets to another database.
    //
    moveToDatabase(assetIds: string[], databaseId: string): Promise<void>;

    //
    // Opens a database file dialog (Electron only).
    //
    openDatabase?: () => Promise<void>;
}

export interface IAssetDatabaseProviderProps {
    children: ReactNode | ReactNode[];
    taskQueueProvider: ITaskQueueProvider;
    restApiUrl: string;
}

export function AssetDatabaseProvider({ children, taskQueueProvider, restApiUrl }: IAssetDatabaseProviderProps) {
    const platform = usePlatform();

    //
    // Set to true while loading assets.
    //
    const [ isLoading, setIsLoading ] = useState(true);

    //
    // The number of asset loads in progress.
    // This number can increase when the user changes sets during the initial load, causing
    // additional database loads to start while the previous ones are still in progress.
    //
    const loadingCount = useRef<number>(0);

    //
    // Counts up IDs for each database currently being loaded.
    //
    const loadingId = useRef<number>(0);

    //
    // Set to true while working on something.
    //
    const [ isWorking, setIsWorking ] = useState(false);

    //
    // Assets that have been loaded.
    //
    const loadedAssets = useRef<IGalleryItemMap>({});

    //
    // The database currently being viewed.
    //
    const [ databaseId, setDatabaseId ] = useState<string | undefined>(undefined);
    
    //
    // The database path currently being used.
    //
    const [ databasePath, setDatabasePath ] = useState<string | undefined>(undefined);

    //
    // Assets that have been loaded.
    //
    function getAssets(): IGalleryItemMap {
        return loadedAssets.current;
    }

    //
    // Subscribes to resets of the gallery.
    //
    const onReset = useRef<IObservable<void>>(new Observable<void>());

    //
    // Subscribes to new gallery items.
    //
    const onNewItems = useRef<IObservable<IGalleryItem[]>>(new Observable<IGalleryItem[]>());

    //
    // Invokes subscriptions for new assets.
    //
    function _onNewItems(assets: IAsset[]) {
        for (const asset of assets) {
            loadedAssets.current[asset._id] = asset;
        }               

        onNewItems.current.invoke(assets);
    }

    const onItemsUpdated = useRef<IObservable<IItemsUpdate>>(new Observable<IItemsUpdate>());

    //
    // Subscribes to gallery item deletions.
    //
    const onItemsDeleted = useRef<IObservable<IItemsUpdate>>(new Observable<IItemsUpdate>());

    //
    // Adds an asset to a particular database.
    //
    async function addAssetToDatabase(asset: IGalleryItem, databaseId: string): Promise<void> {
        const ops: IDatabaseOp[] = [
            {
                collectionName: "metadata",
                recordId: asset._id,
                databaseId,
                op: {
                    type: "set",
                    fields: {
                        ...asset,
                    },
                },
            }
        ];

        //todo: send to main process to apply to the current database.
    }

    //
    // Updates an existing asset.
    //
    async function updateAsset(assetId: string, partialAsset: Partial<IGalleryItem>): Promise<void> {

        if (!databaseId) {
            throw new Error("No database id provided.");
        }

        const updatedAsset = { ...loadedAssets.current[assetId], ...partialAsset };
        loadedAssets.current[assetId] = updatedAsset;

        onItemsUpdated.current.invoke({ assetIds: [ assetId ] });

        const ops: IDatabaseOp[] = [{
            collectionName: "metadata",
            recordId: assetId,
            databaseId,
            op: {
                type: "set",
                fields: partialAsset,
            },
        }];

        //todo: send to main process to apply to the current database.
    }

    //
    // Update multiple assets with persisted database changes.
    //
    async function updateAssets(assetUpdates: { assetId: string, partialAsset: Partial<IGalleryItem>}[]): Promise<void> {

        if (!databaseId) {
            throw new Error("No database id provided.");
        }

        for (const { assetId, partialAsset } of assetUpdates) {
            loadedAssets.current[assetId] = {
                ...loadedAssets.current[assetId],
                ...partialAsset,
            };
        }

        onItemsUpdated.current.invoke({ assetIds: assetUpdates.map(({ assetId }) => assetId) });

        const ops: IDatabaseOp[] = assetUpdates.map(({ assetId, partialAsset }) => ({
            collectionName: "metadata",
            recordId: assetId,
            databaseId,
            op: {
                type: "set",
                fields: partialAsset,
            },
        }));        

        //todo: send to main process to apply to the current database.
    }

    //
    // Adds an array value to the asset.
    //
    async function addArrayValue(assetId: string, field: string, value: any): Promise<void> {

        if (!databaseId) {
            throw new Error("No database id provided.");
        }

        const updatedAsset: any = { ...loadedAssets.current[assetId] };
        if (updatedAsset[field] === undefined) {
            updatedAsset[field] = [];
        }
        updatedAsset[field] = (updatedAsset[field] as any[]).filter(item => item !== value)
        updatedAsset[field].push(value);

        loadedAssets.current[assetId] = updatedAsset;

        onItemsUpdated.current.invoke({ assetIds: [ assetId ] });

        const ops: IDatabaseOp[] = [{
            collectionName: "metadata",
            recordId: assetId,
            databaseId,
            op: {
                type: "push",
                field: field,
                value,
            },
        }];

        //todo: apply operations to the current database.
    }

    //
    // Removes an array value from the asset.
    //
    async function removeArrayValue(assetId: string, field: string, value: any): Promise<void> {

        if (!databaseId) {
            throw new Error("No database id provided.");
        }

        const updatedAsset: any = { ...loadedAssets.current[assetId] };
        if (updatedAsset[field] === undefined) {
            updatedAsset[field] = [];
        }
        updatedAsset[field] = (updatedAsset[field] as any[]).filter(item => item !== value)

        loadedAssets.current[assetId] = updatedAsset;

        onItemsUpdated.current.invoke({ assetIds: [ assetId ] });

        const ops: IDatabaseOp[] = [{
            collectionName: "metadata",
            recordId: assetId,
            databaseId,
            op: {
                type: "pull",
                field: field,
                value,
            },
        }];

        //todo: apply operations to the current database.        
    }

    //
    // Deletes the assets.
    //
    async function deleteAssets(assetIds: string[]): Promise<void> {
        await updateAssets(assetIds.map(assetId => ({
            assetId, 
            partialAsset: { deleted: true } 
        })));

        onItemsDeleted.current.invoke({ assetIds });
    }

    //
    // Opens a database file dialog.
    //
    async function openDatabase(): Promise<void> {
        // Call platform.openDatabase which will trigger the platform to show the dialog
        // and send a 'database-opened' event when a file is selected
        await platform.openDatabase();
        // The database-opened event will be handled by the useEffect listener
    }

    //
    // Moves assets to another database.
    //
    async function moveToDatabase(assetIds: string[], destSetId: string): Promise<void> {

        try {
            setIsWorking(true);

            //
            // Saves asset data to other database.
            //
            for (const assetId of assetIds) {
                const asset = loadedAssets.current[assetId];        
                const uuidGenerator = new RandomUuidGenerator();
                const newAssetId = uuidGenerator.generate();                
                const assetTypes = ["thumb", "display", "asset"];    
                for (const assetType of assetTypes) {
                    const assetData = await loadAsset(assetId, assetType);
                    if (assetData) {
                        await storeAssetToDatabase(newAssetId, assetType, assetData, destSetId);
                    }
                }
    
                //
                // Adds new asset to the database.
                //
                await addAssetToDatabase({ ...asset, _id: newAssetId }, destSetId);
            }
    
            //
            // Deletes the old assets.
            //
            await deleteAssets(assetIds);
        }
        finally {
            setIsWorking(false);
        }
    }


    //
    // Loads data for an asset from the current database.
    //
    async function loadAsset(assetId: string, assetType: string): Promise<Blob | undefined> {
        if (!databasePath) {
            throw new Error("No database path provided.");
        }

        return await loadAssetFromDatabase(assetId, assetType, databasePath);
    }

    //
    // Loads data for an asset from a particular database.
    //
    async function loadAssetFromDatabase(assetId: string, assetType: string, databasePath: string): Promise<Blob> {
        const response = await axios.get(
            `${restApiUrl}/asset?id=${encodeURIComponent(assetId)}&type=${encodeURIComponent(assetType)}&db=${encodeURIComponent(databasePath)}`,
            {
                responseType: "blob",
            }
        );
        return response.data;
    }

    //
    // Stores an asset to the current database.
    //
    async function storeAsset(assetId: string, assetType: string, assetData: Blob): Promise<void> {
        if (!databaseId) {
            throw new Error("No database id provided.");
        }

        await storeAssetToDatabase(assetId, assetType, assetData, databaseId);
    }

    //
    // Stores an asset to a particular database.
    //
    async function storeAssetToDatabase(assetId: string, assetType: string, assetData: Blob, databaseId: string): Promise<void> {
        //todo: store asset data to the current database.
        //todo: what uses this?
    }

    //
    // Gets a gallery item by id.
    //
    function getItemById(assetId: string): IGalleryItem | undefined {
        return loadedAssets.current[assetId];
    }

    //
    // Load assets into memory.
    //
    async function loadAssets(dbPath: string) {
        if (!dbPath) {
            throw new Error("Database path is required");
        }
    
        setIsLoading(true);
        loadingCount.current += 1;
        loadingId.current += 1;

        const latestLoadingId = loadingId.current;

        //
        // Start with no assets.
        // This clears out any existing database of assets.
        //
        loadedAssets.current = {};

        //
        // Pass a gallery reset down the line.
        // This is the starting point for incremental gallery loading.
        //
        onReset.current.invoke();

        // Create the queue once and reuse it
        const queue = await taskQueueProvider.create();

        // Set up listener for task completion before queuing the task
        queue.onTaskComplete<ILoadAssetsData, ILoadAssetsResult>((task, result) => {
            // Check if this is the latest load operation
            if (loadingId.current !== latestLoadingId) {
                //todo: this could be automatic, if the queue is cancelled it shouldn't send messages back.
                return; // This result is from an older load operation
            }

            if (result.status === TaskStatus.Succeeded) {
                // Task completed successfully
                console.log(`Load assets task completed: ${result.outputs?.totalAssets} assets loaded`);
            }
            else if (result.status === TaskStatus.Failed) {
                console.error("Load assets task failed:", result.errorMessage);
            }

            // Mark loading as complete when the task finishes (succeeded or failed)
            loadingCount.current -= 1;
            if (loadingCount.current <= 0) {
                setIsLoading(false);
            }
        });

        // Recieve asset pages.
        queue.onTaskMessage<IAssetPageMessage>("asset-page", data => {
            // Only process messages if we're still on the latest load operation
            if (loadingId.current !== latestLoadingId) {
                return;
            }

            // Message is guaranteed to be an asset-page due to the filter
            if (data.message.batch && data.message.batch.length > 0) {
                _onNewItems(data.message.batch);
            }
        });
        
        // Queue the load-assets task using the same queue instance with database path
        loadAssetsApi(queue, dbPath);
    }

    //
    // Listen for database-opened events from platform.
    //
    useEffect(() => {
        const handleDatabaseOpened = (dbPath: string) => {
            setDatabasePath(dbPath);
            // Use the database path as the databaseId for now
            setDatabaseId(dbPath);
        };

        // Subscribe to database-opened events
        const unsubscribe = platform.onDatabaseOpened(handleDatabaseOpened);

        return () => {
            unsubscribe();
        };
    }, [platform]);

    //
    // Load assets when database path changes.
    //
    useEffect(() => {
        if (databasePath) {
            loadAssets(databasePath)
                .catch(err => {
                    console.error(`Failed to load assets:`);
                    console.error(err);
                });
        }
    }, [databasePath]);

    const value: IAssetDatabase = {
        // Gallery source.
        isLoading,
        isWorking,
        isReadOnly: false,
        getAssets,
        onReset: onReset.current,
        onNewItems: onNewItems.current,
        onItemsUpdated: onItemsUpdated.current,
        onItemsDeleted: onItemsDeleted.current,
        updateAsset,
        updateAssets,
        addArrayValue,
        removeArrayValue,
        deleteAssets,
        loadAsset,
        storeAsset,
        getItemById,

        // Asset database source.
        databaseId,
        setDatabaseId,
        moveToDatabase,
        openDatabase,
    };
    
    return (
        <AssetDatabaseContext.Provider value={value} >
            <GallerySourceContext.Provider value={value} >
                {children}
            </GallerySourceContext.Provider>
        </AssetDatabaseContext.Provider>
    );
}

export const AssetDatabaseContext = createContext<IAssetDatabase | undefined>(undefined);

//
// Use the asset database in a component.
//
export function useAssetDatabase(): IAssetDatabase {
    const context = useContext(AssetDatabaseContext);
    if (!context) {
        throw new Error(`AssetDatabaseContext is not set!.`);
    }
    return context;
}