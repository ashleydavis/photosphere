import React, { ReactNode, createContext, useContext, useEffect, useRef } from "react";
import { IIndexeddbDatabases, IDatabaseConfigurations, IndexeddbDatabases } from "../lib/database/indexeddb/indexeddb-databases";

export interface IIndexeddbContext {
    //
    // Interface for retieving databases.
    //
    databases: IIndexeddbDatabases;
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
            "outgoing-asset-upload",
            "outgoing-asset-update",
            "last-update",
            "user",
        ],
        versionNumber: 1,
    },
};

//
// The version of the database.
// This need to be incremented when the schema changes.
//
const databaseVersion = 1;

export function IndexeddbContextProvider({ children }: IProps) {

    const dbCache = useRef<IndexeddbDatabases>(new IndexeddbDatabases(databaseConfigurations, "collection"));

    useEffect(() => {
        return () => {
            //
            // Close all database connections.
            //
            dbCache.current.shutdown();
        };
    }, []);

    const value: IIndexeddbContext = {
        databases: dbCache.current,
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

