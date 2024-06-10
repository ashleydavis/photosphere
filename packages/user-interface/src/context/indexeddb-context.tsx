import React, { ReactNode, createContext, useContext, useEffect, useRef } from "react";
import { IIndexeddbDatabaseConfiguration, openDatabase } from "../lib/database/indexeddb/indexeddb";
import { IDatabase } from "../lib/database/database";
import { IndexeddbDatabase } from "../lib/database/indexeddb/indexeddb-database";

const databaseConfiguration: IIndexeddbDatabaseConfiguration = {
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
            name: "users",
        },
    ],
    versionNumber: 1,
}

export interface IIndexeddbContext {
    //
    // The application's database.
    //
    database: IDatabase;
}

const IndexeddbContext = createContext<IIndexeddbContext | undefined>(undefined);

export interface IProps {
    children: ReactNode | ReactNode[];
}

export function IndexeddbContextProvider({ children }: IProps) {

    const database = useRef<IDatabase | undefined>(new IndexeddbDatabase(
        async () => {
            indexeddb.current = await openDatabase("photosphere", databaseConfiguration);
            return indexeddb.current;
        }
    ));
    const indexeddb = useRef<IDBDatabase | undefined>(undefined);

    useEffect(() => {
        return () => {
            if (indexeddb.current) {
                indexeddb.current.close();
                indexeddb.current = undefined;
            }

            if (database.current) {
                database.current = undefined;
            }
        };
    }, []);

    const value: IIndexeddbContext = {
        database: database.current!,
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

