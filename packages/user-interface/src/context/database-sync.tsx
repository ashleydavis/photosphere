import React, { ReactNode, createContext, useContext, useEffect, useState } from "react";
import { useOnline } from "../lib/use-online";
import { IAssetUpdateRecord, IAssetUploadRecord } from "./source/outgoing-queue-sink";
import { IGallerySink } from "./source/gallery-sink";
import { useIndexeddb } from "./indexeddb-context";
import { useApi } from "./api-context";
import { IGallerySource } from "./source/gallery-source";
import { isProduction } from "./auth-context";
import { uuid } from "../lib/uuid";
import { IAsset } from "../def/asset";
import { IDatabaseOp } from "../def/ops";

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

    children: ReactNode | ReactNode[];
}

export function DbSyncContextProvider({ cloudSource, cloudSink, indexeddbSource, indexeddbSink, localSource, children }: IProps) {
    
    const { isOnline } = useOnline();
    const { getLeastRecentRecord, deleteRecord, getRecord, storeRecord, getNumRecords } = useIndexeddb();
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
                const numRecords = await getNumRecords(`collection-${collectionId}`, "metadata");
                if (numRecords === 0) {
                    //
                    // Assume that no records means we need to get all records down.
                    //
                    const assets = await cloudSource.getAssets(collectionId);
                    console.log(`Initial sync for ${collectionId}: ${assets.length} assets`);

                    const databaseOps: IDatabaseOp[] = assets.map(asset => ({ 
                        collectionId,
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
                            await storeRecord<any>("debug", "initial-sync-recieved", { _id: uuid(), ops: databaseOps });
                        }
                    }

                    //
                    // Records the latest update id for the collection.
                    //
                    const latestUpdateId = await api.getLatestUpdateId(collectionId);
                    if (latestUpdateId !== undefined) {
                        //
                        // Record the latest update that was received.
                        //
                        await storeRecord<IUpdateIdRecord>("user", "last-update-id", {
                            _id: collectionId,
                            lastUpdateId: latestUpdateId,
                        });
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
            //
            // Flush the queue of outgoing asset uploads.
            //
            while (true) {
                const outgoingUpload = await getLeastRecentRecord<IAssetUploadRecord>("user", "outgoing-asset-upload");
                if (!outgoingUpload) {
                    break;
                }

                await cloudSink.storeAsset(outgoingUpload.collectionId, outgoingUpload.assetId, outgoingUpload.assetType, outgoingUpload.assetData);
                await deleteRecord("user", "outgoing-asset-upload", outgoingUpload._id);

                if (!isProduction) {
                    await storeRecord<any>("debug", "updates-sent", { _id: uuid(), upload: outgoingUpload });
                }

                console.log(`Processed outgoing upload: ${outgoingUpload.collectionId}/${outgoingUpload.assetType}/${outgoingUpload.assetId}`);
            }

            //
            // Flush the queue of outgoing asset updates.
            //
            while (true) {
                const outgoingUpdate = await getLeastRecentRecord<IAssetUpdateRecord>("user", "outgoing-asset-update");
                if (!outgoingUpdate) {
                    break;
                }

                await cloudSink.submitOperations([outgoingUpdate.op]);
                await deleteRecord("user", "outgoing-asset-update", outgoingUpdate._id);

                if (!isProduction) {
                    await storeRecord<any>("debug", "updates-sent", { _id: uuid(), update: outgoingUpdate });
                }

                console.log(`Processed outgoing update: ${outgoingUpdate.op.collectionId}/${outgoingUpdate.op.recordId}`);
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

            //
            // Retreive updates for the collections we have access to, but only
            // from the latest update that was received.
            //
            for (const collectionId of collectionIds) {
                const lastUpdateIdRecord = await getRecord<IUpdateIdRecord>("user", "last-update-id", collectionId);
                const journalResult = await api.getJournal(collectionId, lastUpdateIdRecord?.lastUpdateId);

                if (journalResult.ops.length === 0) {
                    // Nothing to do.
                    break;
                }

                //
                // Apply incoming changes to the local database.
                //
                indexeddbSink.submitOperations(journalResult.ops.map(journalRecord => ({
                    collectionId,
                    collectionName: journalRecord.collectionName,
                    recordId: journalRecord.recordId,
                    op: journalRecord.op,
                })));
                    
                if (!isProduction) {
                    await storeRecord<any>("debug", "updates-recieved", { _id: uuid(), update: journalResult });
                }

                if (journalResult.latestUpdateId !== undefined) {
                    //
                    // Record the latest update that was received.
                    //
                    await storeRecord<IUpdateIdRecord>("user", "last-update-id", {
                        _id: collectionId, 
                        lastUpdateId: journalResult.latestUpdateId,
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