import React, { ReactNode, createContext, useContext, useEffect, useRef, useState } from "react";
import { IGalleryItem } from "../lib/gallery-item";
import { IAssetData } from "../def/asset-data";
import { GallerySourceContext, IAssetDataLoad, IGalleryItemMap, IGallerySource } from "./gallery-source";
import { IAsset, IDatabaseOp } from "defs";
import { PersistentQueue } from "../lib/sync/persistent-queue";
import dayjs from "dayjs";
import { IAssetRecord } from "../def/asset-record";
import { useApi } from "./api-context";
import { useApp } from "./app-context";
import { applyOperations } from "../lib/apply-operation";
import { useOnline } from "../lib/use-online";
import { useIndexeddb } from "./indexeddb-context";
import { syncOutgoing } from "../lib/sync/sync-outgoing";
import { syncIncoming } from "../lib/sync/sync-incoming";
import { initialSync } from "../lib/sync/initial-sync";
import { IOutgoingUpdate } from "../lib/sync/outgoing-update";
import { uuid } from "../lib/uuid";

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

    const { user } = useApp();
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
    const [ assets, setAssets ] = useState<IGalleryItemMap>({});

    //
    // The set currently being viewed.
    //
    const [ setId, setSetId ] = useState<string | undefined>(undefined);

    //
    // Adds an asset to the default set.
    //
    function addAsset(asset: IGalleryItem): void {
        if (!setId) {
            throw new Error("No set id provided.");
        }

        setAssets({
            ...assets,
            [asset._id]: asset,        
        });

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
                op: {
                    type: "set",
                    fields: {
                        _id: asset._id,
                        width: asset.width,
                        height: asset.height,
                        origFileName: asset.origFileName,
                        origPath: asset.origPath,
                        contentType: asset.contentType,
                        hash: asset.hash,
                        location: asset.location,
                        fileDate: asset.fileDate,
                        photoDate: asset.photoDate,
                        uploadDate: dayjs().toISOString(),
                        properties: asset.properties,
                        labels: asset.labels,
                        description: asset.description,
                        setId,
                        usetId: asset.userId,
                    },
                },
            }
        ];

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
    // Updates an existing asset.
    //
    async function updateAsset(assetId: string, partialAsset: Partial<IGalleryItem>): Promise<void> {

        const updatedAsset = { ...assets[assetId], ...partialAsset };
        setAssets({
            ...assets,
            [assetId]: updatedAsset,
        });

        const ops: IDatabaseOp[] = [{
            collectionName: "metadata",
            recordId: assetId,
            op: {
                type: "set",
                fields: partialAsset,
            },
        }];

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
            ])
            .catch(err => {
                console.error(`Failed to update asset:`);
                console.error(err);
            });
    }

    //
    // Update multiple assets with persisted database changes.
    //
    async function updateAssets(assetUpdates: { assetId: string, partialAsset: Partial<IGalleryItem>}[]): Promise<void> {
        let _assets = {
            ...assets,
        };
        for (const { assetId, partialAsset } of assetUpdates) {
            _assets[assetId] = { ..._assets[assetId], ...partialAsset };
        }
        setAssets(_assets);

        const ops: IDatabaseOp[] = assetUpdates.map(({ assetId, partialAsset }) => ({
            collectionName: "metadata",
            recordId: assetId,
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

        const updatedAsset: any = { ...assets[assetId] };
        if (updatedAsset[field] === undefined) {
            updatedAsset[field] = [];
        }
        updatedAsset[field] = (updatedAsset[field] as any[]).filter(item => item !== value)
        updatedAsset[field].push(value);

        setAssets({
            ...assets,
            [assetId]: updatedAsset,
        });

        const ops: IDatabaseOp[] = [{
            collectionName: "metadata",
            recordId: assetId,
            op: {
                type: "push",
                field: field,
                value,
            },
        }];

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
            ])
            .catch(err => {
                console.error(`Failed to update asset:`);
                console.error(err);
            });
    }

    //
    // Removes an array value from the asset.
    //
    async function removeArrayValue(assetId: string, field: string, value: any): Promise<void> {
        
        const updatedAsset: any = { ...assets[assetId] };
        if (updatedAsset[field] === undefined) {
            updatedAsset[field] = [];
        }
        updatedAsset[field] = (updatedAsset[field] as any[]).filter(item => item !== value)
  
        setAssets({
            ...assets,
            [assetId]: updatedAsset,
        });

        const ops: IDatabaseOp[] = [{
            collectionName: "metadata",
            recordId: assetId,
            op: {
                type: "pull",
                field: field,
                value,
            },
        }];

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
            ])
            .catch(err => {
                console.error(`Failed to update asset:`);
                console.error(err);
            });
    }

    //
    // Deletes the assets.
    //
    async function deleteAssets(assetIds: string[]): Promise<void> {
        await updateAssets(assetIds.map(assetId => ({
            assetId, 
            partialAsset: { deleted: true } 
        })));
    }

    //
    // Moves assets to another set.
    //
    async function moveToSet(assetIds: string[], destSetId: string): Promise<void> {

        try {
            setIsWorking(true);

            //
            // Initializes the destination set.
            //
            await initialSync(database, destSetId, api, 0, assets => {
                console.log(`Loaded ${assets.length} assets into ${setId}`);
                return true;
            });            

            //
            // Saves asset data to other set.
            //
            for (const assetId of assetIds) {
                const asset = assets[assetId];        
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
        const assets = await database.collection<IAsset>("metadata").getAllByIndex("hash", hash);
        return assets.length > 0;
    }

    //
    // Loads data for an asset from the current set.
    //
    async function loadAsset(assetId: string, assetType: string): Promise<IAssetDataLoad | undefined> {
        if (!setId) {
            throw new Error("No set id provided.");
        }

        return await loadAssetFromSet(assetId, assetType, setId);
    }

    //
    // Loads data for an asset from a particular set.
    //
    async function loadAssetFromSet(assetId: string, assetType: string, setId: string): Promise<IAssetDataLoad | undefined> {
        const assetRecord = await database.collection<IAssetRecord>(assetType).getOne(assetId);
        if (assetRecord) {
            return {
                ...assetRecord.assetData,
                source: "local",
            };
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
            source: "cloud",
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
    // Periodic synchronization.
    //
    useEffect(() => {
        if (periodicSyncStarted.current) {
            console.log(`Periodic sync already started.`);
            return;
        }

        let timer: NodeJS.Timeout | undefined = undefined;
        let done = false;
        
        if (!isLoading && isOnline && user) {
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
            
                try {
                    //
                    // Collate the last update ids for each collection.
                    //
                    const setIds = user!.sets.map(set => set.id);
                    await syncIncoming({ setIds, database, api });
                }
                catch (err) {
                    console.error(`Incoming sync failed:`);
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

    }, [isLoading, isOnline, user]);

    //
    // Load assets into memory.
    //
    async function loadAssets(setId: string) {
    
        try {
            setIsLoading(true);
            loadingCount.current += 1;
            loadingId.current += 1;

            //
            // Start with no assets.
            // This clears out any existing set of assets.
            //
            setAssets({});

            await initialSync(database, setId, api, loadingId.current, (assets, setIndex) => {
                if (setIndex !== loadingId.current) {
                    // The set we are loading has changed.
                    // Stop loading assets.
                    return false; 
                }

                const assetMap: IGalleryItemMap = {};
                for (const asset of assets) {
                    assetMap[asset._id] = asset;
                }               

                //
                // As each page of assets are loaded update the asset map in state.
                //
                setAssets(assetMap);

                console.log(`Loaded ${assets.length} assets for set ${setId}`);

                return true; // Continue loading assets.
            });
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
        assets,
        addAsset,
        updateAsset,
        updateAssets,
        addArrayValue,
        removeArrayValue,
        deleteAssets,
        checkAssetHash,
        loadAsset,
        storeAsset,

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