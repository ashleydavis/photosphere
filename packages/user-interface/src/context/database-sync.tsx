import React, { ReactNode, createContext, useContext, useEffect, useRef, useState } from "react";
import { useOnline } from "../lib/use-online";
import { useIndexeddb } from "./indexeddb-context";
import { useApi } from "./api-context";
import { IIndexeddbDatabases } from "../lib/indexeddb/indexeddb-databases";
import { IAssetUpdateRecord } from "../lib/sync/asset-update-record";
import { IAssetUploadRecord } from "../lib/sync/asset-upload-record";
import { IPersistentQueue } from "../lib/sync/persistent-queue";
import { syncIncoming } from "../lib/sync/sync-incoming";
import { syncOutgoing } from "../lib/sync/sync-outgoing";
import { IUser } from "../def/user";
import { initialSync } from "../lib/sync/sync-initial";

const SYNC_POLL_PERIOD = 5000;

export interface IDbSyncContext {
    //
    // Set to true when the database synchronization is initialized.
    //
    isInitialized: boolean;

    //
    // The current user, if known.
    //
    user: IUser | undefined;
}

const DbSyncContext = createContext<IDbSyncContext | undefined>(undefined);

export interface IProps {

    //
    // Interface to the local indexeddb databases.
    //
    indexeddbDatabases: IIndexeddbDatabases;

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

export function DbSyncContextProvider({ outgoingAssetUploadQueue, outgoingAssetUpdateQueue, indexeddbDatabases, children }: IProps) {
    
    const { isOnline } = useOnline();
    const indexeddb = useIndexeddb();
    const api = useApi();
    const [ user, setUser ] = useState<IUser | undefined>(undefined);
    const initialSyncStarted = useRef(false);
    const periodicSyncStart = useRef(false);

    //
    // Set to true when the database synchronization is initialized.
    //
    const [isInitialized, setIsInitialized] = useState(false);

    //
    // Loads the local user's details.
    //
    async function loadLocalUser(): Promise<void> {
        const userId = localStorage.getItem("userId");
        if (!userId) {
            return undefined;
        }

        const userDatabase = indexeddb.databases.database("user");
        const user = await userDatabase.collection<IUser>("user").getOne(userId);
        if (user) {
            setUser(user);
        }
        else {
            setUser(undefined);
        }
    }

    //
    // Loads the user's details.
    //
    async function loadUser(): Promise<void> {
        if (isOnline) {
            // Not able to load user details offline.
            const user = await await api.getUser();
            if (user) {
                //
                // Store user locally for offline use.
                //
                const userDatabase = indexeddb.databases.database("user");
                await userDatabase.collection("user").setOne("user", user);
                localStorage.setItem("userId", user._id);
                setUser(user);
                return;
            }
        }

        // Fallback to local user.
        await loadLocalUser();
    }

    useEffect(() => {
        loadUser()
            .catch(err => {
                console.error(`Failed to load user:`);
                console.error(err)            
            });
    }, [api.isInitialised, isOnline]);

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
                        await initialSync({ setIds, api, indexeddbDatabases });
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
                    await syncIncoming({ setIds, indexeddbDatabases, api });
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
        user,
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
