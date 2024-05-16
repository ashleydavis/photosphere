import { IDatabase, IDatabaseConfigurations, IndexeddbDatabases } from "database";
import { version } from "os";
import React, { ReactNode, createContext, useContext, useEffect, useRef, useState } from "react";

export interface IIndexeddbContext {
    //
    // Gets an indexedb database.
    //
    database(databaseName: string): IDatabase;
}

const IndexeddbContext = createContext<IIndexeddbContext | undefined>(undefined);

export interface IProps {
    children: ReactNode | ReactNode[];
}

//
// The configuration for each type of database.
//
const databaseConfigurations: IDatabaseConfigurations = {
    collection: {
        collectionNames: [
            "thumb",
            "display",
            "asset",
            "hashes",
            "metadata",
        ],
        versionNumber: 1,
    },
    user: {    
        collectionNames: [
            "last-update-id",
            "user",
        ],
        versionNumber: 1,
    },
    debug: { // For debugging.
        collectionNames: [                 
            "updates-recieved",
            "updates-sent",
            "initial-sync-recieved",
        ],
        versionNumber: 1,
    },     
};

//
// The version of the database.
// This need to be incremented when the schema changes.
//
const databaseVersion = 2;

export function IndexeddbContextProvider({ children }: IProps) {

    const dbCache = useRef<IndexeddbDatabases>(new IndexeddbDatabases(databaseConfigurations));

    useEffect(() => {
        return () => {
            //
            // Close all database connections.
            //
            dbCache.current.shutdown();
        };
    }, []);

    //
    // Gets an indexedb database.
    //
    function database(databaseName: string): IDatabase {
        return dbCache.current.database(databaseName);    
    }

    const value: IIndexeddbContext = {
        database,
    };
    
    return (
        <IndexeddbContext.Provider value={value} >
            {children}
        </IndexeddbContext.Provider>
    );
}

//
// Use the Indexeddb context in a component.
//
export function useIndexeddb(): IIndexeddbContext {
    const context = useContext(IndexeddbContext);
    if (!context) {
        throw new Error(`Indexeddb context is not set! Add IndexeddbContextProvider to the component tree.`);
    }
    return context;
}

