import React, { ReactNode, createContext, useContext, useEffect } from "react";
import { useOnline } from "../lib/use-online";
import { IAssetUpdateRecord, IAssetUploadRecord } from "./source/outgoing-queue-sink";
import { IGallerySink } from "./source/gallery-sink";
import { useIndexeddb } from "./indexeddb-context";
import { ICollectionUpdateIds, useApi } from "./api-context";
import { IGallerySource } from "./source/gallery-source";

const SYNC_POLL_PERIOD = 1000;

//
// Records last update ids for each collection in the local database.
//
interface ILastUpdateIds {
    [collectionId: string]: string;
}

export interface IDbSyncContext {
}

const DbSyncContext = createContext<IDbSyncContext | undefined>(undefined);

export interface IProps {
    cloudSink: IGallerySink;
    indexeddbSink: IGallerySink;
    localSource: IGallerySource;

    children: ReactNode | ReactNode[];
}

export function DbSyncContextProvider({ cloudSink, indexeddbSink, localSource, children }: IProps) {
    
    const { isOnline } = useOnline();
    const { getLeastRecentRecord, deleteRecord, getRecord, storeRecord } = useIndexeddb();
    const api = useApi();

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

                await cloudSink.uploadAsset(outgoingUpload.collectionId, outgoingUpload.assetId, outgoingUpload.assetType, outgoingUpload.contentType, outgoingUpload.data);
                await deleteRecord("user", "outgoing-asset-upload", outgoingUpload._id);
            }

            //
            // Flush the queue of outgoing asset updates.
            //
            while (true) {
                const outgoingUpdate = await getLeastRecentRecord<IAssetUpdateRecord>("user", "outgoing-asset-update");
                if (!outgoingUpdate) {
                    break;
                }

                await cloudSink.updateAsset(outgoingUpdate.collectionOps);
                await deleteRecord("user", "outgoing-asset-update", outgoingUpdate._id);
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
            const lastUpdateIds: ICollectionUpdateIds = {};
            for (const collectionId of collectionIds) {
                const lastUpdateForCollection = await getRecord<ILastUpdateIds>("user", "last-update-id", collectionId);
                if (lastUpdateForCollection) {
                    lastUpdateIds[collectionId] = lastUpdateForCollection.latestUpdateId;
                }
            }

            //
            // Retreive updates for the collections we have access to, but only
            // from the latest update that was received.
            //
            const { collectionOps } = await api.retrieveOperations(lastUpdateIds);

            for (const collectionOp of collectionOps) {
                //
                // Apply incoming changes to the local database.
                //
                indexeddbSink.updateAsset(collectionOp.collectionOps);
        
                if (collectionOp.latestUpdateId !== undefined) {
                    //
                    // Record the latest update that was received.
                    //
                    await storeRecord<ILastUpdateIds>("user", "last-update-id", {
                        _id: collectionOp.collectionOps.id, 
                        latestUpdateId: collectionOp.latestUpdateId
                    });
                }
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

                await syncOutgoing();
                await syncIncoming();

                timer = setTimeout(periodicSync, SYNC_POLL_PERIOD);
            }

            //
            // Starts the database synchronization process.
            //
            async function startSync() {
                //
                // Starts the periodic syncrhonization process.
                //
                timer = setTimeout(periodicSync, SYNC_POLL_PERIOD);
            }

            startSync();
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