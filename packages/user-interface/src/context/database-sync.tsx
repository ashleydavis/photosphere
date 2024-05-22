import React, { ReactNode, createContext, useContext, useEffect, useState } from "react";
import { useOnline } from "../lib/use-online";
import { useIndexeddb } from "./indexeddb-context";
import { useApi } from "./api-context";
import { IAsset, IAssetUpdateRecord, IAssetUploadRecord, IAssetSink, IAssetSource, IPersistentQueue, syncIncoming, syncOutgoing, initialSync, IDatabases, IIndexeddbDatabases, IUser } from "database";

const SYNC_POLL_PERIOD = 1000;

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
    // Interface to the database in the cloud.
    //
    cloudDatabases: IDatabases;

    //
    // Interface to the local indexeddb databases.
    //
    indexeddbDatabases: IIndexeddbDatabases;

    cloudSource: IAssetSource;
    cloudSink: IAssetSink;
    indexeddbSource: IAssetSource;
    indexeddbSink: IAssetSink;
    localSource: IAssetSource;

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

export function DbSyncContextProvider({ cloudDatabases, cloudSource, cloudSink, indexeddbDatabases, indexeddbSource, indexeddbSink, localSource, outgoingAssetUploadQueue, outgoingAssetUpdateQueue, children }: IProps) {
    
    const { isOnline } = useOnline();
    const indexeddb = useIndexeddb();
    const api = useApi();
    const [ user, setUser ] = useState<IUser | undefined>(undefined);

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
        let timer: NodeJS.Timeout | undefined = undefined;
        let done = false;
       
        if (isOnline) {
            if (user) {
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
                            cloudSink,
                            cloudDatabases,
                            outgoingAssetUploadQueue,
                            outgoingAssetUpdateQueue,
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
                        const collectionIds = user!.collections.access;
                        const userDatabase = indexeddb.databases.database("user");
                        await syncIncoming({ collectionIds, api, userDatabase, indexeddbSink, cloudDatabases });
                    }
                    catch (err) {
                        console.error(`Outgoing sync failed:`);
                        console.error(err);
                    }
        
                    timer = setTimeout(periodicSync, SYNC_POLL_PERIOD);
                }
    
                //
                // Starts the database synchronization process.
                //
                async function startSync() {
    
                    try {
                        //
                        // Collate the last update ids for each collection.
                        //
                        const collectionIds = user!.collections.access;
    
                        await initialSync({ collectionIds, api, cloudDatabases, cloudSource, indexeddbDatabases, indexeddbSource, indexeddbSink });
                    }
                    catch (err) {
                        console.error(`Initial sync failed:`);
                        console.error(err);
                    }
                    finally {
                        console.log(`Marking isInitialized as true.`); //fio:
                        setIsInitialized(true);
                    }
    
                    //
                    // Starts the periodic syncrhonization process.
                    //
                    await periodicSync();
                }
    
                startSync();
            }
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

    }, [isOnline, user]);

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
