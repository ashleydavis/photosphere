import React, { ReactNode, createContext, useContext, useEffect, useRef, useState } from "react";
import { useOnline } from "../lib/use-online";
import { useIndexeddb } from "./indexeddb-context";
import { useApi } from "./api-context";
import { IAssetUpdateRecord } from "../lib/sync/asset-update-record";
import { IAssetUploadRecord } from "../lib/sync/asset-upload-record";
import { IPersistentQueue } from "../lib/sync/persistent-queue";
import { syncIncoming } from "../lib/sync/sync-incoming";
import { syncOutgoing } from "../lib/sync/sync-outgoing";
import { initialSync } from "../lib/sync/sync-initial";
import { useApp } from "./app-context";
import { IDatabase } from "../lib/database/database";

const SYNC_POLL_PERIOD = 5000;

export interface IDbSyncContext {
    //
    // Set to true when the database synchronization is initialized.
    //
    isInitialized: boolean;
}

const DbSyncContext = createContext<IDbSyncContext | undefined>(undefined);

export interface IProps {

    //
    // Interface to the local indexeddb database.
    //
    database: IDatabase; //todo: can just get this through the context.

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

export function DbSyncContextProvider({ outgoingAssetUploadQueue, outgoingAssetUpdateQueue, database, children }: IProps) {
    
    const { isOnline } = useOnline();
    const api = useApi();
    const initialSyncStarted = useRef(false);
    const periodicSyncStart = useRef(false);
    const { user } = useApp();

    //
    // Set to true when the database synchronization is initialized.
    //
    const [isInitialized, setIsInitialized] = useState(false);

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
                        outgoingAssetUploadQueue,
                        outgoingAssetUpdateQueue,
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
