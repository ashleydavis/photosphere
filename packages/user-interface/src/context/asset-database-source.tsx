import React, { ReactNode, createContext, useContext, useEffect, useRef, useState } from "react";
import { IGalleryItem } from "../lib/gallery-item";
import { IAssetData } from "../def/asset-data";
import { GallerySourceContext, IItemsUpdate, IGalleryItemMap, IGallerySource } from "./gallery-source";
import { IAsset, IDatabaseOp } from "defs";
import { PersistentQueue } from "../lib/sync/persistent-queue";
import dayjs from "dayjs";
import { IAssetRecord } from "../def/asset-record";
import { IGetAllResponse, useApi } from "./api-context";
import { useApp } from "./app-context";
import { applyOperations } from "../lib/apply-operation";
import { useOnline } from "../lib/use-online";
import { useIndexeddb } from "./indexeddb-context";
import { syncOutgoing } from "../lib/sync/sync-outgoing";
import { IOutgoingUpdate } from "../lib/sync/outgoing-update";
import { retry, uuid } from "utils";
import { IObservable, Observable } from "../lib/subscription";

const SYNC_POLL_PERIOD = 60 * 1000; // 1 minute.

//
// Adds "asset database" specific functionality to the gallery source.
//
export interface IAssetDatabase extends IGallerySource {
    //
    // The currently viewed set.
    //
    setId: string | undefined;

    //
    // Sets the viewed set.
    //
    setSetId(setId: string): void;

    //
    // Moves assets to another set.
    //
    moveToSet(assetIds: string[], setId: string): Promise<void>;
}

export interface IAssetDatabaseProviderProps {
    children: ReactNode | ReactNode[];
}

export function AssetDatabaseProvider({ children }: IAssetDatabaseProviderProps) {

    const { sets } = useApp();
    const { isOnline } = useOnline();
    const api = useApi();
    const { database } = useIndexeddb();

    const outgoingUpdateQueue = useRef<PersistentQueue<IOutgoingUpdate>>(new PersistentQueue<IOutgoingUpdate>(database, "outgoing-updates"));
    const periodicSyncStarted = useRef(false);

    //
    // Set to true while loading assets.
    //
    const [ isLoading, setIsLoading ] = useState(true);

    //
    // The number of asset loads in progress.
    // This number can increase when the user changes sets during the initial load, causing
    // additional set loads to start while the previous ones are still in progress.
    //
    const loadingCount = useRef<number>(0);

    //
    // Counts up IDs for each set currently being loaded.
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
    // The set currently being viewed.
    //
    const [ setId, setSetId ] = useState<string | undefined>(undefined);

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
    // Adds an asset to the default set.
    //
    function addAsset(item: IGalleryItem): void {
        if (!setId) {
            throw new Error("No set id provided.");
        }

        const asset: IAsset = {
            ...item,
        };

        _onNewItems([ asset ]); 

        addAssetToSet(asset, setId)
            .catch(err => {
                console.error(`Failed to add asset:`);
                console.error(err);
            });
    }

    //
    // Adds an asset to a particular set.
    //
    async function addAssetToSet(asset: IGalleryItem, setId: string): Promise<void> {
        const ops: IDatabaseOp[] = [
            {
                collectionName: "metadata",
                recordId: asset._id,
                setId,
                op: {
                    type: "set",
                    fields: {
                        ...asset,
                        uploadDate: dayjs().toISOString(),
                        setId, //TODO: Shouldn't be needed.
                    },
                },
            }
        ];

        //
        // Queue the updates for upload to the cloud.
        //
        await outgoingUpdateQueue.current.add({
            type: "update",
            ops,
        });
    }

    //
    // Updates an existing asset.
    //
    async function updateAsset(assetId: string, partialAsset: Partial<IGalleryItem>): Promise<void> {

        if (!setId) {
            throw new Error("No set id provided.");
        }

        const updatedAsset = { ...loadedAssets.current[assetId], ...partialAsset };
        loadedAssets.current[assetId] = updatedAsset;

        onItemsUpdated.current.invoke({ assetIds: [ assetId ] });

        const ops: IDatabaseOp[] = [{
            collectionName: "metadata",
            recordId: assetId,
            setId,
            op: {
                type: "set",
                fields: partialAsset,
            },
        }];

        //
        // Queue the updates for upload to the cloud.
        //
        await outgoingUpdateQueue.current.add({
            type: "update",
            ops,
        });
    }

    //
    // Update multiple assets with persisted database changes.
    //
    async function updateAssets(assetUpdates: { assetId: string, partialAsset: Partial<IGalleryItem>}[]): Promise<void> {

        if (!setId) {
            throw new Error("No set id provided.");
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
            setId,
            op: {
                type: "set",
                fields: partialAsset,
            },
        }));        

        await Promise.all([
            //
            // Updates the local database.
            //
            applyOperations(database, ops),

            //
            // Queue the updates for upload to the cloud.
            //
            outgoingUpdateQueue.current.add({ 
                type: "update",
                ops,
            }),
        ]);
    }

    //
    // Adds an array value to the asset.
    //
    async function addArrayValue(assetId: string, field: string, value: any): Promise<void> {

        if (!setId) {
            throw new Error("No set id provided.");
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
            setId,
            op: {
                type: "push",
                field: field,
                value,
            },
        }];

        //
        // Queue the updates for upload to the cloud.
        //
        await outgoingUpdateQueue.current.add({
            type: "update",
            ops,
        });
    }

    //
    // Removes an array value from the asset.
    //
    async function removeArrayValue(assetId: string, field: string, value: any): Promise<void> {

        if (!setId) {
            throw new Error("No set id provided.");
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
            setId,
            op: {
                type: "pull",
                field: field,
                value,
            },
        }];


        //
        // Queue the updates for upload to the cloud.
        //
        await outgoingUpdateQueue.current.add({
            type: "update",
            ops,
        })
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
    // Moves assets to another set.
    //
    async function moveToSet(assetIds: string[], destSetId: string): Promise<void> {

        try {
            setIsWorking(true);

            //
            // Saves asset data to other set.
            //
            for (const assetId of assetIds) {
                const asset = loadedAssets.current[assetId];        
                const newAssetId = uuid();                
                const assetTypes = ["thumb", "display", "asset"];    
                for (const assetType of assetTypes) {
                    const assetData = await loadAsset(assetId, assetType);
                    if (assetData) {
                        await storeAssetToSet(newAssetId, assetType, assetData, destSetId);
                    }
                }
    
                //
                // Adds new asset to the database.
                //
                await addAssetToSet({ ...asset, _id: newAssetId }, destSetId);
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
    // Checks if an asset is already uploaded.
    //
    async function checkAssetHash(hash: string): Promise<boolean> {
        if (!setId) {
            throw new Error("No set id provided.");
        }

        return await api.checkAssetHash(setId, hash);
    }

    //
    // Loads data for an asset from the current set.
    //
    async function loadAsset(assetId: string, assetType: string): Promise<IAssetData | undefined> {
        if (!setId) {
            throw new Error("No set id provided.");
        }

        return await loadAssetFromSet(assetId, assetType, setId);
    }

    //
    // Loads data for an asset from a particular set.
    //
    async function loadAssetFromSet(assetId: string, assetType: string, setId: string): Promise<IAssetData | undefined> {
        const assetRecord = await database.collection<IAssetRecord>(assetType).getOne(assetId);
        if (assetRecord) {
            return assetRecord.assetData;
        }

        if (!isOnline) {
            return undefined;
        }
        
        //
        // Fallback to cloud.
        //
        const assetBlob = await api.getAsset(setId!, assetId, assetType);
        if (!assetBlob) {
            return undefined;
        }

        //
        // Save a local version.
        //
        database.collection<IAssetRecord>(assetType).setOne({
                _id: assetId,
                storeDate: new Date(),
                assetData: {
                    contentType: assetBlob.type,
                    data: assetBlob,
                },
            })
            .catch(err => {
                console.error(`Failed to store asset locally:`);
                console.error(err);            
            });

        return {
            contentType: assetBlob.type,
            data: assetBlob,
        };
    }

    //
    // Stores an asset to the current set.
    //
    async function storeAsset(assetId: string, assetType: string, assetData: IAssetData): Promise<void> {
        if (!setId) {
            throw new Error("No set id provided.");
        }

        await storeAssetToSet(assetId, assetType, assetData, setId);
    }

    //
    // Stores an asset to a particular set.
    //
    async function storeAssetToSet(assetId: string, assetType: string, assetData: IAssetData, setId: string): Promise<void> {
        // 
        // Store the asset locally.
        //
        await database.collection<IAssetRecord>(assetType).setOne({
            _id: assetId,
            storeDate: new Date(),
            assetData,
        });

        // 
        // Queue the asset for upload to the cloud.
        //
        await outgoingUpdateQueue.current.add({
            type: "upload",
            setId: setId!,
            assetId,
            assetType,
            assetData,
        });
    }

    //
    // Gets a gallery item by id.
    //
    function getItemById(assetId: string): IGalleryItem | undefined {
        return loadedAssets.current[assetId];
    }

    //
    // Periodic synchronization.
    //
    useEffect(() => {
        if (periodicSyncStarted.current) {
            console.log(`Periodic sync already started.`);
            return;
        }

        let timer: NodeJS.Timeout | undefined = undefined;
        let done = false;
        
        if (!isLoading && isOnline && sets) {
            periodicSyncStarted.current = true;

            // 
            // Periodic database synchronization.
            //
            async function periodicSync() {
                timer = undefined;

                if (done) {
                    return;
                }

                console.log(`Periodic sync...`);

                try {
                    await syncOutgoing({
                        outgoingUpdateQueue: outgoingUpdateQueue.current,
                        api,
                    });
                }
                catch (err) {
                    console.error(`Outgoing sync failed:`);
                    console.error(err);
                }
            
                console.log(`Periodic sync done.`);
    
                timer = setTimeout(periodicSync, SYNC_POLL_PERIOD);
            }

            //
            // Starts the periodic syncrhonization process.
            //
            periodicSync();
        }

        return () => {
            done = true;
            periodicSyncStarted.current = false;
            if (timer) {
                clearTimeout(timer);
                timer = undefined;
            }
        };

    }, [isLoading, isOnline, sets]);

    //
    // Load assets into memory.
    //
    async function loadAssets(setId: string) {
    
        try {
            setIsLoading(true);
            loadingCount.current += 1;
            loadingId.current += 1;

            const latestLoadingId = loadingId.current;

            //
            // Start with no assets.
            // This clears out any existing set of assets.
            //
            loadedAssets.current = {};

            //
            // Pass a gallery reset down the line.
            // This is the starting point for incremental gallery loading.
            //
            onReset.current.invoke();

            let next: string  | undefined = undefined;

            //
            // Load the assets from the cloud into memory.
            //
            do {
                //
                // Get a page of assets from the backend.
                // Assumes the backend gives us the assets in sorted order.
                //
                const result: IGetAllResponse<IAsset> = await retry(
                    () => api.getAll<IAsset>(setId, "metadata", next),
                    5, // Attempts
                    600, // Starting wait time
                    2, // Double the weight time on each retry.
                );
                if (result.records.length === 0) {
                    // No more records.
                    break;
                }

                //
                // Continue if the set index matches the current loading index.
                // This allows loading to be aborted if the user changes what they are looking at.
                //
                const shouldContinue = latestLoadingId === loadingId.current;
                if (!shouldContinue) {
                    // Request to abort asset loading.
                    return;
                }     

                setTimeout(() => {
                    _onNewItems(result.records);  // Starts the next request before setting the new assets.

                    console.log(`Loaded ${result.records.length} assets for set ${setId}`);
                }, 0);

                next = result.next;
            } while (next);
        }
        finally {
            loadingCount.current -= 1;
            if (loadingCount.current <= 0) {
                setIsLoading(false);
            }
        }
    }

    //
    // Load assets.
    //
    useEffect(() => {
        if (setId) {
            loadAssets(setId)
                .catch(err => {
                    console.error(`Failed to load assets:`);
                    console.error(err);
                });
        }
    }, [setId]);

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
        addAsset,
        updateAsset,
        updateAssets,
        addArrayValue,
        removeArrayValue,
        deleteAssets,
        checkAssetHash,
        loadAsset,
        storeAsset,
        getItemById,

        // Asset database source.
        setId,
        setSetId,
        moveToSet,
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