import React, { ReactNode, useEffect, useRef, useState } from "react";
import { IGalleryItem } from "../lib/gallery-item";
import { IAssetData } from "../def/asset-data";
import { GallerySourceContext, IGallerySource } from "./gallery-source";
import { IAsset, IDatabaseOp } from "defs";
import { PersistentQueue } from "../lib/sync/persistent-queue";
import { IAssetUploadRecord } from "../lib/sync/asset-upload-record";
import { IAssetUpdateRecord } from "../lib/sync/asset-update-record";
import dayjs from "dayjs";
import { IAssetRecord } from "../def/asset-record";
import { IApi, useApi } from "./api-context";
import { useApp } from "./app-context";
import { applyOperations } from "../lib/apply-operation";
import { useOnline } from "../lib/use-online";
import { useIndexeddb } from "./indexeddb-context";
import { syncOutgoing } from "../lib/sync/sync-outgoing";
import { syncIncoming } from "../lib/sync/sync-incoming";
import { ILastUpdateRecord } from "../lib/sync/last-update-record";

const SYNC_POLL_PERIOD = 5000;

export interface IAssetDatabaseProviderProps {
    children: ReactNode | ReactNode[];
}

export function AssetDatabaseProvider({ children }: IAssetDatabaseProviderProps) {

    const { setId, user } = useApp();
    const { isOnline } = useOnline();
    const api = useApi();
    const { database } = useIndexeddb();

    const outgoingAssetUploadQueue = useRef<PersistentQueue<IAssetUploadRecord>>(new PersistentQueue<IAssetUploadRecord>(database, "outgoing-asset-upload"));
    const outgoingAssetUpdateQueue = useRef<PersistentQueue<IAssetUpdateRecord>>(new PersistentQueue<IAssetUpdateRecord>(database, "outgoing-asset-update"));
    const periodicSyncStarted = useRef(false);

    //
    // Set to true while loading assets.
    //
    const [ isLoading, setIsLoading ] = useState(true);

    //
    // Assets that have been loaded.
    //
    const [ assets, setAssets ] = useState<IGalleryItem[]>([]);

    //
    // Adds an asset to the source (if not readonly).
    //
    async function addAsset(galleryItem: IGalleryItem): Promise<void> {
        const ops: IDatabaseOp[] = [
            {
                collectionName: "metadata",
                recordId: galleryItem._id,
                op: {
                    type: "set",
                    fields: {
                        _id: galleryItem._id,
                        width: galleryItem.width,
                        height: galleryItem.height,
                        origFileName: galleryItem.origFileName,
                        origPath: galleryItem.origPath,
                        contentType: galleryItem.contentType,
                        hash: galleryItem.hash,
                        location: galleryItem.location,
                        fileDate: galleryItem.fileDate,
                        photoDate: galleryItem.photoDate,
                        sortDate: galleryItem.sortDate,
                        uploadDate: dayjs().toISOString(),
                        properties: galleryItem.properties,
                        labels: galleryItem.labels,
                        description: galleryItem.description,
                        setId,
                    },
                },
            }
        ];

        //
        // Updates the local database.
        //
        await applyOperations(database, ops);        

        //
        // Queue the updates for upload to the cloud.
        //
        await outgoingAssetUpdateQueue.current.add({ 
            ops,
        });       
    }

    //
    // Updates an existing asset.
    //
    async function updateAsset(assetId: string, partialGalleryItem: Partial<IGalleryItem>): Promise<void> {
        const ops: IDatabaseOp[] = [{
            collectionName: "metadata",
            recordId: assetId,
            op: {
                type: "set",
                fields: partialGalleryItem,
            },
        }]

        //
        // Updates the local database.
        //
        await applyOperations(database, ops);        

        //
        // Queue the updates for upload to the cloud.
        //
        await outgoingAssetUpdateQueue.current.add({ 
            ops,
        });
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
    async function loadAsset(assetId: string, assetType: string): Promise<IAssetData | undefined> {
        if (!setId) {
            throw new Error("No set id provided.");
        }

        const assetRecord = await database.collection<IAssetRecord>(assetType).getOne(assetId);
        if (assetRecord) {
            return assetRecord.assetData;
        }

        if (!isOnline) {
            return undefined;
        }
        
        // Fallback to cloud.
        const assetBlob = await api.getAsset(setId, assetId, assetType);
        return {
            contentType: assetBlob.type,
            data: assetBlob,
        };
    }

    //
    // Stores an asset.
    //
    async function storeAsset(assetId: string, assetType: string, assetData: IAssetData): Promise<void> {
        if (!setId) {
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
        await outgoingAssetUploadQueue.current.add({
            setId,
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
                        outgoingAssetUploadQueue: outgoingAssetUploadQueue.current,
                        outgoingAssetUpdateQueue: outgoingAssetUpdateQueue.current,
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
                    const setIds = user!.sets.access;    
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

            let assets = await database.collection<IAsset>("metadata").getAllByIndex("setId", setId);
            if (assets.length > 0) {
                setAssets(assets);
            }
            else {
                //
                // Records the time of the latest update for the set.
                // This should be done before the initial sync to avoid missing updates.
                //
                const latestTime = await api.getLatestTime();

                //
                // Load the assets from the cloud into memory.
                //
                let skip = 0;
                const pageSize = 1000;
                while (true) {
                    const records = await api.getAll<IAsset>(setId, "metadata", skip, pageSize);
                    if (records.length === 0) {
                        // No more records.
                        break;
                    }

                    skip += pageSize;
                    assets = assets.concat(records);
                    setAssets(assets);

                    console.log(`Loaded ${assets.length} assets.`)
                }
                
                if (latestTime !== undefined) {
                    //
                    // Record the latest time where updates were received.
                    //
                    database.collection<ILastUpdateRecord>("last-update").setOne({ 
                        _id: setId,
                        lastUpdateTime: latestTime,
                    });
                }

                //
                // Save the assets to the local database.
                //
                const localCollection = database.collection("metadata");
                for (const asset of assets) {
                    await localCollection.setOne(asset); // Store it locally.
                }
            }        
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
