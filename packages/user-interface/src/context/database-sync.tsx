import React, { ReactNode, createContext, useContext, useEffect, useRef, useState } from "react";
import { useOnline } from "../lib/use-online";
import { IAssetUpdateRecord, IAssetUploadRecord } from "./source/outgoing-queue-sink";
import { IGallerySink } from "./source/gallery-sink";
import { useIndexeddb } from "./indexeddb-context";
import { useApi } from "./api-context";
import { IGallerySource } from "./source/gallery-source";
import { isProduction } from "./auth-context";
import { uuid } from "../lib/uuid";
import { IAsset } from "../def/asset";
import { IDatabaseOp } from "database";
import { IPersistentQueue, useOutgoingUpdateQueue } from "./persistent-queue";

const SYNC_POLL_PERIOD = 1000;

//
// Records last update ids for each collection in the local database.
//
interface IUpdateIdRecord {
    //
    // The ID of the record.
    //
    _id: string;

    //
    // The last update id for the collection.
    //
    lastUpdateId: string;
}

export interface IDbSyncContext {
    //
    // Set to true when the database synchronization is initialized.
    //
    isInitialized: boolean;
}

const DbSyncContext = createContext<IDbSyncContext | undefined>(undefined);

export interface IProps {
    cloudSource: IGallerySource;
    cloudSink: IGallerySink;
    indexeddbSource: IGallerySource;
    indexeddbSink: IGallerySink;
    localSource: IGallerySource;

    //
    // Queues outgoing asset uploads.
    //
    outgoingAssetUploadQueue: IPersistentQueue<IAssetUploadRecord>;

    //
    // Queues outgoing asset updates.
    //
    outgoingAssetUpdateQueue: IPersistentQueue<IAssetUpdateRecord>;

    children: ReactNode | ReactNode[];
}

export function DbSyncContextProvider({ cloudSource, cloudSink, indexeddbSource, indexeddbSink, localSource, outgoingAssetUploadQueue, outgoingAssetUpdateQueue, children }: IProps) {
    
    const { isOnline } = useOnline();
    const indexeddb = useIndexeddb();
    const api = useApi();

    //
    // Set to true when the database synchronization is initialized.
    //
    const [isInitialized, setIsInitialized] = useState(false);

    //
    // Perform the initial synchronization.
    //
    async function initialSync() {
        
        try {
            const user = await localSource.getUser();
            if (!user) {
                throw new Error("User not found");
            }

            for (const collectionId of user.collections.access) {
                const assetCollection = await indexeddb.database(`collection-${collectionId}`);
                const noRecords = await assetCollection.collection("metadata").none();
                if (noRecords) {
                    //
                    // Records the latest update id for the collection.
                    // This should be done before the initial sync to avoid missing updates.
                    //
                    const latestUpdateId = await api.getLatestUpdateId(collectionId);
                    if (latestUpdateId !== undefined) {
                        //
                        // Record the latest update that was received.
                        //
                        const userDatabase = await indexeddb.database("user");
                        userDatabase.collection<any>("last-update-id").setOne(collectionId, { lastUpdateId: latestUpdateId });
                    }

                    //
                    // Assume that no records means we need to get all records down.
                    //
                    const assets = await cloudSource.getAssets(collectionId);
                    console.log(`Initial sync for ${collectionId}: ${assets.length} assets`);

                    const databaseOps: IDatabaseOp[] = assets.map(asset => ({ 
                        databaseName: collectionId,
                        collectionName: "metadata",
                        recordId: asset._id,
                        op: {
                            type: "set",
                            fields: asset,
                        },
                    }));
                    await indexeddbSink.submitOperations(databaseOps);

                    if (!isProduction) {
                        if (databaseOps.length > 0) {
                            const debugDatabase = await indexeddb.database("debug");
                            debugDatabase.collection<any>("initial-sync-recieved").setOne(uuid(), { ops: databaseOps });
                        }
                    }
                }

                //
                // Pre-cache all thumbnails.
                //
                const assets = await indexeddbSource.getAssets(collectionId);
                await Promise.all(assets.map(asset => cacheThumbnail(collectionId, asset)));
            }
        }
        catch (err) {
            console.error(`Initial sync failed:`);
            console.error(err);
        }
    }

    //
    // Pre-caches a thumbnail.
    //
    async function cacheThumbnail(collectionId: string, asset: IAsset) {
        const localThumbData = await indexeddbSource.loadAsset(collectionId, asset._id, "thumb");
        if (localThumbData === undefined) {
            const assetData = await cloudSource.loadAsset(collectionId, asset._id, "thumb");
            if (assetData) {
                await indexeddbSink.storeAsset(collectionId, asset._id, "thumb", assetData);
                // console.log(`Cached thumbnail for ${collectionId}/${asset._id}`);
            }
        }
        else {
            // console.log(`Thumbnail for ${collectionId}/${asset._id} already cached`);
        }
    }

    //
    // Send outgoing asset uploads and updates to the cloud.
    //
    async function syncOutgoing() {
        try {
            const userDatabase = await indexeddb.database("user");

            //
            // Flush the queue of outgoing asset uploads.
            //
            while (true) {
                const outgoingUpload = await outgoingAssetUploadQueue.getNext();
                if (!outgoingUpload) {
                    break;
                }

                await cloudSink.storeAsset(outgoingUpload.collectionId, outgoingUpload.assetId, outgoingUpload.assetType, outgoingUpload.assetData);
                await outgoingAssetUploadQueue.removeNext();

                if (!isProduction) {
                    const debugDatabase = await indexeddb.database("debug");
                    await debugDatabase.collection<any>("updates-sent").setOne(uuid(), { upload: outgoingUpload });
                }

                console.log(`Processed outgoing upload: ${outgoingUpload.collectionId}/${outgoingUpload.assetType}/${outgoingUpload.assetId}`);
            }

            //
            // Flush the queue of outgoing asset updates.
            //
            while (true) {
                const outgoingUpdate = await outgoingAssetUpdateQueue.getNext();
                if (!outgoingUpdate) {
                    break;
                }

                await cloudSink.submitOperations(outgoingUpdate.ops);
                await outgoingAssetUpdateQueue.removeNext();
 
                if (!isProduction) {
                    const debugDatabase = await indexeddb.database("debug");
                    await debugDatabase.collection<any>("updates-sent").setOne(uuid(), { update: outgoingUpdate });
                }

                console.log(`Processed outgoing updates:`);
                for (const op of outgoingUpdate.ops) {
                    console.log(`  ${op.databaseName}/${op.collectionName}/${op.recordId}`);
                }
            }
        }
        catch (err) {
            console.error(`Outgoing sync failed:`);
            console.error(err);
        }
    }    

    //
    // Receive incoming asset uploads and updates from the cloud.
    //
    async function syncIncoming() {

        try {
            //
            // Collate the last update ids for each collection.
            //
            const user = await localSource.getUser();
            if (!user) {
                throw new Error("User not found");
            }

            const collectionIds = user.collections.access;

            const userDatabase = await indexeddb.database("user");

            //
            // Retreive updates for the collections we have access to, but only
            // from the latest update that was received.
            //
            for (const collectionId of collectionIds) {
                const lastUpdateIdCollection = userDatabase.collection<IUpdateIdRecord>("last-update-id");
                const lastUpdateIdRecord = await lastUpdateIdCollection.getOne(collectionId);
                const journalResult = await api.getJournal(collectionId, lastUpdateIdRecord?.lastUpdateId);

                if (journalResult.ops.length === 0) {
                    // Nothing to do.
                    break;
                }

                //
                // Apply incoming changes to the local database.
                //
                indexeddbSink.submitOperations(journalResult.ops.map(journalRecord => ({
                    databaseName: collectionId,
                    collectionName: journalRecord.collectionName,
                    recordId: journalRecord.recordId,
                    op: journalRecord.op,
                })));
                    
                if (!isProduction) {
                    const debugDatabase = await indexeddb.database("debug");
                    await debugDatabase.collection<any>("updates-recieved").setOne(uuid(), { update: journalResult });
                }

                if (journalResult.latestUpdateId !== undefined) {
                    //
                    // Record the latest update that was received.
                    //
                    await lastUpdateIdCollection.setOne(collectionId, { 
                        _id: collectionId, 
                        lastUpdateId: journalResult.latestUpdateId 
                    });
                }
               
                console.log(`Processed incoming updates for ${collectionId}: ${journalResult.ops.length} ops`);
            }
        }
        catch (err) {
            console.error(`Incoming sync failed:`);
            console.error(err);
        }
    }

    useEffect(() => {
        let timer: NodeJS.Timeout | undefined = undefined;
        let done = false;
       
        if (isOnline) {
            // 
            // Periodic database synchronization.
            //
            async function periodicSync() {
                timer = undefined;

                if (done) {
                    return;
                }

                console.log(`Periodic sync...`);

                await syncOutgoing();
                await syncIncoming();

                timer = setTimeout(periodicSync, SYNC_POLL_PERIOD);
            }

            //
            // Starts the database synchronization process.
            //
            async function startSync() {

                try {
                    await initialSync();
                }
                finally {
                    setIsInitialized(true);
                }

                //
                // Starts the periodic syncrhonization process.
                //
                await periodicSync();
            }

            startSync();
        }
        else {
            setIsInitialized(true);
        }

        return () => {
            done = true;
            if (timer) {
                clearTimeout(timer);
                timer = undefined;
            }
        };

    }, [isOnline]);

    const value: IDbSyncContext = {
    	isInitialized,
    };
    
    return (
        <DbSyncContext.Provider value={value} >
            {children}
        </DbSyncContext.Provider>
    );
}

//
// Periodically synchorize the local database with the cloud database.
//
export function useDatabaseSync() {
    const context = useContext(DbSyncContext);
    if (!context) {
        throw new Error(`DbSyncContext is not set! Add DbSyncContext to the component tree.`);
    }
    return context;
}