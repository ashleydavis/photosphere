import React, { ReactNode, useEffect, useRef, useState } from "react";
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

const SYNC_POLL_PERIOD = 5000;

export interface IAssetDatabaseProviderProps {
    children: ReactNode | ReactNode[];
}

export function AssetDatabaseProvider({ children }: IAssetDatabaseProviderProps) {

    const { setId, user } = useApp();
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
    // Assets that have been loaded.
    //
    const [ assets, setAssets ] = useState<IGalleryItemMap>({});

    //
    // Adds an asset to the source.
    //
    function addAsset(asset: IGalleryItem, overrideSetId?: string): void {

        setAssets({
            ...assets,
            [asset._id]: asset,        
        });
           
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
                        sortDate: asset.sortDate,
                        uploadDate: dayjs().toISOString(),
                        properties: asset.properties,
                        labels: asset.labels,
                        description: asset.description,
                        setId: overrideSetId || setId,
                        usetId: asset.userId,
                    },
                },
            }
        ];

        //
        // Don't have to wait for these slow operations to complete.
        //
        Promise.all([
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
                console.error(`Failed to add asset:`);
                console.error(err);
            });
    }

    //
    // Updates an existing asset.
    //
    function updateAsset(assetId: string, partialAsset: Partial<IGalleryItem>): void {

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

        //
        // Don't have to wait for these slow operations to complete.
        //
        Promise.all([
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
    // Update multiple assets with non persisted changes.
    //
    function updateAssets(assetUpdates: { assetId: string, partialAsset: Partial<IGalleryItem>}[]): void {

        let _assets = {
            ...assets,
        }
        assetUpdates.forEach(({ assetId, partialAsset }) => {
            _assets[assetId] = { ..._assets[assetId], ...partialAsset };
        });
        setAssets(_assets);
    }

    //
    // Adds an array value to the asset.
    //
    function addArrayValue(assetId: string, field: string, value: any): void {

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

        //
        // Don't have to wait for these slow operations to complete.
        //
        Promise.all([
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
    function removeArrayValue(assetId: string, field: string, value: any): void {
        
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

        //
        // Don't have to wait for these slow operations to complete.
        //
        Promise.all([
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
    // Deletes the asset.
    //
    function deleteAsset(assetId: string): void {
        updateAsset(assetId, {
            deleted: true,
        });
    }

    //
    // Moves selected asset to the requested set.
    //
    async function moveToSet(assetId: string, destSetId: string): Promise<void> {

        const newAssetId = uuid();

        //
        // Saves asset data to other set.
        //
        const asset = assets[assetId];        
        const assetTypes = ["thumb", "display", "asset"];    
        for (const assetType of assetTypes) {
            const assetData = await loadAsset(asset._id, assetType);
            if (assetData) {
                await storeAsset(newAssetId, assetType, assetData, destSetId);
            }
        }

        //
        // Adds new asset to the datbaase.
        //
        addAsset({ ...asset, _id: newAssetId }, destSetId);

        //
        // Deletes the old asset.
        //
        deleteAsset(assetId);
    }

    //
    // Checks if an asset is already uploaded.
    //
    async function checkAssetHash(hash: string): Promise<boolean> {
        const assets = await database.collection<IAsset>("metadata").getAllByIndex("hash", hash);
        return assets.length > 0;
    }

    //
    // Loads data for an asset.
    //
    async function loadAsset(assetId: string, assetType: string, overrideSetId?: string): Promise<IAssetDataLoad | undefined> {
        if (!overrideSetId && !setId) {
            throw new Error("No set id provided.");
        }

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
        const assetBlob = await api.getAsset(overrideSetId || setId!, assetId, assetType);
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
    // Stores an asset.
    //
    async function storeAsset(assetId: string, assetType: string, assetData: IAssetData, overrideSetId?: string): Promise<void> {
        if (!overrideSetId && !setId) {
            throw new Error("No set id provided.");
        }

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
            setId: overrideSetId || setId!,
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

            const assets = await initialSync(database, setId, api, assets => {
                const assetMap: IGalleryItemMap = {};
                for (const asset of assets) {
                    assetMap[asset._id] = asset;
                }               

                setAssets(assetMap);

                console.log(`Loaded ${assets.length} assets.`);
            });            
        }
        finally {
            setIsLoading(false);
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

    const value: IGallerySource = {
        isLoading,
        isReadOnly: false,
        assets,
        addAsset,
        updateAsset,
        updateAssets,
        addArrayValue,
        removeArrayValue,
        deleteAsset,
        moveToSet,
        checkAssetHash,
        loadAsset,
        storeAsset,
    };
    
    return (
        <GallerySourceContext.Provider value={value} >
            {children}
        </GallerySourceContext.Provider>
    );
}

