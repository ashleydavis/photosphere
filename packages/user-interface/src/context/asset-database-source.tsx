import React, { ReactNode, createContext, useContext, useEffect, useRef, useState } from "react";
import { IGalleryItem } from "../lib/gallery-item";
import { GallerySourceContext, IItemsUpdate, IGalleryItemMap, IGallerySource } from "./gallery-source";
import { IAsset, IDatabaseOp } from "defs";
import { RandomUuidGenerator } from "utils";
import { IObservable, Observable } from "../lib/subscription";
import { loadAssets as loadAssetsApi } from "api/src/lib/load-assets";
import type { IAssetPageMessage, ILoadAssetsData, ILoadAssetsResult } from "api/src/lib/load-assets.types";
import type { ISyncBatchMessage } from "api/src/lib/sync-database.types";
import axios from "axios";
import { TaskStatus } from "task-queue";
import type { ITaskQueueProvider } from "task-queue";
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
    // Closes the current database.
    //
    closeDatabase(): Promise<void>;

    //
    // Moves assets to another database.
    //
    moveToDatabase(assetIds: string[], databasePath: string): Promise<void>;

    //
    // Opens a database file dialog (Electron only).
    //
    selectAndOpenDatabase(): Promise<void>;

    //
    // Shows a directory picker, creates a new database there, and loads it.
    //
    selectAndCreateDatabase(): Promise<void>;

    //
    // Opens a database by path directly (without showing file dialog).
    //
    openDatabase(dbPath: string): Promise<void>;

    //
    // True while a background sync with the origin database is in progress.
    //
    isSyncing: boolean;

    //
    // Returns a direct URL for an asset, suitable for use in img src attributes.
    //
    assetUrl(assetId: string, assetType: string): string;
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
    const [ isLoading, setIsLoading ] = useState(false);

    //
    // Set to true while a background sync with the origin database is in progress.
    //
    const [ isSyncing, setIsSyncing ] = useState(false);

    //
    // The database path currently being loaded (if any).
    //
    const loadingDatabasePath = useRef<string | undefined>(undefined);

    //
    // Unsubscribe function for the current load's task queue callbacks.
    //
    const unsubscribeCurrentLoad = useRef<(() => void) | undefined>(undefined);

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
    // Persists metadata operations via the local REST API (same process as GET /asset in Electron).
    //
    async function persistDatabaseOps(ops: IDatabaseOp[]): Promise<void> {
        if (ops.length === 0) {
            return;
        }

        await axios.post(`${restApiUrl}/apply-database-ops`, { ops }, {
            headers: { "Content-Type": "application/json" },
        });
        platform.notifyDatabaseEdited();
    }

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

        await persistDatabaseOps(ops);
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

        await persistDatabaseOps(ops);
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

        await persistDatabaseOps(ops);
    }

    //
    // Adds an array value to the asset.
    //
    async function addArrayValue(assetId: string, field: string, value: any): Promise<void> {

        if (!databasePath) {
            throw new Error("No database path provided.");
        }

        const updatedAsset: any = { ...loadedAssets.current[assetId] };
        if (updatedAsset[field] === undefined || !Array.isArray(updatedAsset[field])) {
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

        await persistDatabaseOps(ops);
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

        await persistDatabaseOps(ops);
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
    // Shows a directory picker, creates a new database there, and loads it.
    //
    async function selectAndCreateDatabase(): Promise<void> {
        await platform.createDatabase();

        // The database-opened event will be handled by the useEffect listener
    }

    //
    // Opens a database by path directly (without showing file dialog).
    //
    async function openDatabase(dbPath: string): Promise<void> {
        if (databasePath) {
            await closeDatabase();
        }

        // Directly set the database path to trigger loading
        setDatabasePath(dbPath);

        // Notify platform that database was opened (adds to recent databases and updates menu)
        await platform.notifyDatabaseOpened(dbPath);
    }
    
    //
    // Closes the current database.
    //
    async function closeDatabase(): Promise<void> {
        if (databasePath) {
            cancelDatabaseLoad(databasePath);
        }

        setIsLoading(false);
        setIsSyncing(false);
        loadingDatabasePath.current = undefined;
        setDatabasePath(undefined);
        loadedAssets.current = {};
        onReset.current.invoke();
        await platform.notifyDatabaseClosed();
    }
   
    //
    // Moves assets to another database.
    //
    async function moveToDatabase(assetIds: string[], destDatabasePath: string): Promise<void> {

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
                        await storeAssetToDatabase(newAssetId, assetType, assetData, destDatabasePath);
                    }
                }
    
                //
                // Adds new asset to the database.
                //
                await addAssetToDatabase({ ...asset, _id: newAssetId }, destDatabasePath);
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
    // Stores binary asset data (thumb / display / original) into a database via the local REST API.
    // Used by moveToDatabase and by storeAsset for the current database.
    //
    async function storeAssetToDatabase(assetId: string, assetType: string, assetData: Blob, databasePath: string): Promise<void> {
        const params = new URLSearchParams({
            id: assetId,
            type: assetType,
            db: databasePath,
        });
        await axios.post(`${restApiUrl}/asset?${params.toString()}`, assetData);
    }

    //
    // Gets a gallery item by id.
    //
    function getItemById(assetId: string): IGalleryItem | undefined {
        return loadedAssets.current[assetId];
    }

    //
    // Cancels an in-progress database load and cleans up its subscriptions.
    //
    function cancelDatabaseLoad(dbPath: string): void {
        taskQueueProvider.get().cancelTasks(dbPath);
        if (unsubscribeCurrentLoad.current) {
            unsubscribeCurrentLoad.current();
            unsubscribeCurrentLoad.current = undefined;
        }
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
        if (loadingDatabasePath.current !== undefined) {
            console.log(`[loadAssets] Cancelling previous load for database: ${loadingDatabasePath.current}`);
            cancelDatabaseLoad(loadingDatabasePath.current);
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

        const queue = taskQueueProvider.get();

        // Store the database path at the time the load started
        const currentDatabasePath = dbPath;

        // Set up listener for task completion before queuing the task
        const unsubscribeComplete = queue.onTaskComplete<ILoadAssetsData, ILoadAssetsResult>((task, result) => {
            if (task.type === "load-assets") {
                if (result.status === TaskStatus.Succeeded) {
                    console.log(`Load assets task completed: ${result.outputs?.totalAssets} assets loaded`);
                }
                else {
                    console.error("Load assets task failed:", result.errorMessage);
                }

                if (task.data.databasePath === currentDatabasePath) {
                    loadingDatabasePath.current = undefined;
                    setIsLoading(false);

                    if (result.status !== TaskStatus.Succeeded) {
                        // Loading failed — cancel pending tasks and unsubscribe.
                        cancelDatabaseLoad(currentDatabasePath);
                    }
                    else {
                        // Loading succeeded — unsubscribe callbacks. Any prefetch task will still
                        // run in the queue but we don't need to track its completion.
                        if (unsubscribeCurrentLoad.current) {
                            unsubscribeCurrentLoad.current();
                            unsubscribeCurrentLoad.current = undefined;
                        }
                    }
                }
            }
        });

        // Receive asset pages.
        const unsubscribeMessage = queue.onTaskMessage<IAssetPageMessage>("asset-page", data => {
            // Discard messages that belong to a different (now-closed) database.
            if (data.message.databasePath !== currentDatabasePath) {
                return;
            }

            // Message is guaranteed to be an asset-page due to the filter
            if (data.message.batch && data.message.batch.length > 0) {
                _onNewItems(data.message.batch);
            }
        });

        unsubscribeCurrentLoad.current = () => {
            unsubscribeComplete();
            unsubscribeMessage();
        };

        // Queue the load-assets task using the same queue instance with database path
        loadAssetsApi(queue, dbPath);
    }

    //
    // Listen for database-opened and database-closed events from platform.
    //
    useEffect(() => {
        // Subscribe to database events
        const unsubscribeOpened = platform.onDatabaseOpened((dbPath: string) => {
            if (databasePath) {
                closeDatabase().catch(err => {
                    console.error('Error closing database:', err);
                });
            }
            setDatabasePath(dbPath);
        });

        const unsubscribeClosed = platform.onDatabaseClosed(() => {
            closeDatabase().catch(err => {
                console.error('Error closing database:', err);
            });
        });

        return () => {
            unsubscribeOpened();
            unsubscribeClosed();
        };
    }, [platform]);

    //
    // Subscribe to sync-started and sync-completed events from the platform.
    //
    useEffect(() => {
        const unsubscribeStarted = platform.onSyncStarted(() => {
            setIsSyncing(true);
        });

        const unsubscribeCompleted = platform.onSyncCompleted(() => {
            setIsSyncing(false);
        });

        return () => {
            unsubscribeStarted();
            unsubscribeCompleted();
        };
    }, [platform]);

    //
    // Subscribe to incremental sync-batch task messages and apply changes live to the gallery.
    //
    useEffect(() => {
        const queue = taskQueueProvider.get();
        const unsubscribeSyncBatch = queue.onTaskMessage<ISyncBatchMessage>("sync-batch", (data) => {
            const batch = data.message as ISyncBatchMessage;
            if (batch.databasePath !== databasePath) {
                return;
            }

            if (batch.added.length > 0) {
                _onNewItems(batch.added);
            }

            if (batch.updated.length > 0) {
                for (const asset of batch.updated) {
                    loadedAssets.current[asset._id] = asset;
                }
                onItemsUpdated.current.invoke({ assetIds: batch.updated.map(asset => asset._id) });
            }

            if (batch.deletedIds.length > 0) {
                for (const assetId of batch.deletedIds) {
                    delete loadedAssets.current[assetId];
                }
                onItemsDeleted.current.invoke({ assetIds: batch.deletedIds });
            }
        });

        return () => { unsubscribeSyncBatch(); };
    }, [databasePath]);

    //
    // Subscribe to import-success task messages and add newly imported assets to the gallery
    // immediately, so the user sees them without needing to reload.
    //
    useEffect(() => {
        const unsubscribeImportSuccess = platform.onTaskMessage((_taskId, message) => {
            if (message.type !== 'import-success') {
                return;
            }

            const asset = message.asset as IAsset | undefined;
            if (!asset) {
                return;
            }

            _onNewItems([asset]);
        });

        return () => { unsubscribeImportSuccess(); };
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

        // Cleanup: cancel tasks and unsubscribe if component unmounts or database path changes
        return () => {
            if (databasePath) {
                cancelDatabaseLoad(databasePath);
            }
            loadingDatabasePath.current = undefined;
        };
    }, [databasePath]);

    const value: IAssetDatabase = {
        // Gallery source.
        isLoading,
        isSyncing,
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
        getItemById,

        // Asset database source.
        assetUrl: (assetId, assetType) => `${restApiUrl}/asset?id=${encodeURIComponent(assetId)}&type=${encodeURIComponent(assetType)}&db=${encodeURIComponent(databasePath || "")}`,
        databasePath,
        setDatabasePath,
        closeDatabase,
        moveToDatabase,
        selectAndOpenDatabase,
        selectAndCreateDatabase,
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