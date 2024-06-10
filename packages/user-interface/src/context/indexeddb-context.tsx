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
        collections: [
            {
                name: "thumb",
            },
            {
                name: "display",
            },
            {
                name: "asset",
            },
            {
                name: "hashes",
            },
            {
                name: "metadata",
                indexKeys: [ "setId" ],
            },
        ],
        versionNumber: 1,
    },
    user: {    
        collections: [
            {
                name: "outgoing-asset-upload",
            },
            {
                name: "outgoing-asset-update",
            },
            {
                name: "last-update",
            },
            {
                name: "user",
            },
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

