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
import { initialSync } from "../lib/sync/sync-initial";
import { syncOutgoing } from "../lib/sync/sync-outgoing";
import { syncIncoming } from "../lib/sync/sync-incoming";

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
    const initialSyncStarted = useRef(false);
    const periodicSyncStart = useRef(false);

    //
    // Set to true when the source is initialized.
    //
    const [ isInitialized, setIsInitialized ] = useState(false);

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
    // Initial synchronization.
    //
    useEffect(() => {
        if (initialSyncStarted.current) {
            console.log(`Already doing the initial sync.`);
            return;
        }

        if (isOnline) {
            if (user) {
                initialSyncStarted.current = true;

                //
                // Starts the database synchronization process.
                //
                async function startSync() {
                    try {
                        console.log(`Doing initial sync...`);

                        const setIds = user!.sets.access;    
                        await initialSync({ setIds, api, database });
                    }
                    catch (err) {
                        console.error(`Initial sync failed:`);
                        console.error(err);
                    }
                    finally {
                        console.log(`Finished initial sync`);
                        setIsInitialized(true);

                        initialSyncStarted.current = false;
                    }
                }
    
                startSync();
            }
        }
        else {
            setIsInitialized(true);
        }

    }, [isOnline, user]);

    //
    // Periodic synchronization.
    //
    useEffect(() => {
        if (periodicSyncStart.current) {
            console.log(`Periodic sync already started.`);
            return;
        }

        let timer: NodeJS.Timeout | undefined = undefined;
        let done = false;
        
        if (isInitialized && isOnline && user) {
            periodicSyncStart.current = true;

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
            periodicSyncStart.current = false;
            if (timer) {
                clearTimeout(timer);
                timer = undefined;
            }
        };

    }, [isInitialized, isOnline, user]);

    //
    // Load assets.
    //
    useEffect(() => {
        if (isInitialized) {
            async function loadAssets() {
                const assets = await database.collection<IAsset>("metadata").getAllByIndex("setId", setId);
                setAssets(assets);
            }

            loadAssets()
                .catch(err => {
                    console.error(`Failed to load assets:`);
                    console.error(err);
                });
        }
    }, [isInitialized, setId]);

    const value: IGallerySource = {
        isInitialized,
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
