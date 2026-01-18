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
import type { ITaskQueueProvider, ITaskQueue } from "task-queue";
import { usePlatform } from "./platform-context";

//
// Adds "asset database" specific functionality to the gallery source.
//
export interface IAssetDatabase extends IGallerySource {
    //
    // The currently viewed database path.
    //
    databasePath: string | undefined;

    //
    // Sets the viewed database.
    //
    setDatabasePath(databasePath: string): void;

    //
    // Moves assets to another database.
    //
    moveToDatabase(assetIds: string[], databasePath: string): Promise<void>;

    //
    // Opens a database file dialog (Electron only).
    //
    selectAndOpenDatabase(): Promise<void>;

    //
    // Opens a database by path directly (without showing file dialog).
    //
    openDatabase(dbPath: string): Promise<void>;
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
    // The database path currently being loaded (if any).
    //
    const loadingDatabasePath = useRef<string | undefined>(undefined);

    //
    // The queue currently being used for loading assets.
    //
    const currentQueue = useRef<ITaskQueue | undefined>(undefined);

    //
    // Set to true while working on something.
    //
    const [ isWorking, setIsWorking ] = useState(false);

    //
    // Assets that have been loaded.
    //
    const loadedAssets = useRef<IGalleryItemMap>({});

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
    async function addAssetToDatabase(asset: IGalleryItem, databasePath: string): Promise<void> {
        const ops: IDatabaseOp[] = [
            {
                collectionName: "metadata",
                recordId: asset._id,
                databaseId: databasePath,
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

        if (!databasePath) {
            throw new Error("No database path provided.");
        }

        const updatedAsset = { ...loadedAssets.current[assetId], ...partialAsset };
        loadedAssets.current[assetId] = updatedAsset;

        onItemsUpdated.current.invoke({ assetIds: [ assetId ] });

        const ops: IDatabaseOp[] = [{
            collectionName: "metadata",
            recordId: assetId,
            databaseId: databasePath,
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

        if (!databasePath) {
            throw new Error("No database path provided.");
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
            databaseId: databasePath,
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

        if (!databasePath) {
            throw new Error("No database path provided.");
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
            databaseId: databasePath,
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

        if (!databasePath) {
            throw new Error("No database path provided.");
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
            databaseId: databasePath,
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
    async function selectAndOpenDatabase(): Promise<void> {
        // Call platform.openDatabase which will trigger the platform to show the dialog
        // and send a 'database-opened' event when a file is selected
        await platform.openDatabase();

        // The database-opened event will be handled by the useEffect listener
    }

    //
    // Opens a database by path directly (without showing file dialog).
    //
    async function openDatabase(dbPath: string): Promise<void> {
        // Directly set the database path to trigger loading
        setDatabasePath(dbPath);

        // Add to recent databases and update last database (don't await to avoid blocking)
        platform.addRecentDatabase(dbPath)
            .catch(err => {
                console.error("Failed to add database to recent list:", err);
            });
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
        if (!databasePath) {
            throw new Error("No database path provided.");
        }

        await storeAssetToDatabase(assetId, assetType, assetData, databasePath);
    }

    //
    // Stores an asset to a particular database.
    //
    async function storeAssetToDatabase(assetId: string, assetType: string, assetData: Blob, databasePath: string): Promise<void> {
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

        // If a load is already in progress for the same database path, just return
        if (loadingDatabasePath.current === dbPath) {
            console.log(`[loadAssets] Load already in progress for database: ${dbPath}, skipping`);
            return;
        }

        // If a load is in progress for a different database path, cancel it
        if (currentQueue.current !== undefined) {
            console.log(`[loadAssets] Cancelling previous load for database: ${loadingDatabasePath.current}`);
            currentQueue.current.shutdown();
            currentQueue.current = undefined;
        }
    
        console.log(`[loadAssets] Starting load for database: ${dbPath}`);
        loadingDatabasePath.current = dbPath;
        setIsLoading(true);

        //
        // Start with no assets.
        // This clears out any existing database of assets.
        //
        console.log(`[loadAssets] Clearing loadedAssets.current`);
        loadedAssets.current = {};

        //
        // Pass a gallery reset down the line.
        // This is the starting point for incremental gallery loading.
        //
        onReset.current.invoke();

        // Create the queue once and reuse it
        const queue = await taskQueueProvider.create();
        currentQueue.current = queue;

        // Store the database path at the time the queue was created
        const currentDatabasePath = dbPath;

        // Set up listener for task completion before queuing the task
        queue.onTaskComplete<ILoadAssetsData, ILoadAssetsResult>((task, result) => {
            if (result.status === TaskStatus.Succeeded) {
                // Task completed successfully
                console.log(`Load assets task completed: ${result.outputs?.totalAssets} assets loaded`);
            }
            else if (result.status === TaskStatus.Failed) {
                console.error("Load assets task failed:", result.errorMessage);
            }

            // Mark loading as complete when the task finishes (succeeded or failed)
            if (loadingDatabasePath.current === currentDatabasePath) {
                loadingDatabasePath.current = undefined;
                if (currentQueue.current) {
                    currentQueue.current.shutdown();
                    currentQueue.current = undefined;
                }
                setIsLoading(false);
            }
        });

        // Recieve asset pages.
        queue.onTaskMessage<IAssetPageMessage>("asset-page", data => {
            // Only process messages if we're still on the current load operation
            if (loadingDatabasePath.current !== currentDatabasePath) {
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
    // This can result from the user selecting a database from the file dialog.
    //
    useEffect(() => {
        const handleDatabaseOpened = (dbPath: string) => {
            setDatabasePath(dbPath);
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
        databasePath,
        setDatabasePath,
        moveToDatabase,
        selectAndOpenDatabase,
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