import React, { ReactNode, createContext, useContext, useEffect, useRef } from "react";
import { IIndexeddbDatabaseConfiguration, deleteDatabase as _deleteDatabase, openDatabase } from "../lib/database/indexeddb/indexeddb";
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
            name: "outgoing-updates",
        },
    ],
    versionNumber: 4,
}

export interface IIndexeddbContext {
    //
    // The application's database.
    //
    database: IDatabase;

    //
    // Deletes the local copy of the database.
    //
    deleteDatabase(): Promise<void>;
}

const IndexeddbContext = createContext<IIndexeddbContext | undefined>(undefined);

export interface IProps {
    children: ReactNode | ReactNode[];
}

export function IndexeddbContextProvider({ children }: IProps) {

    const database = useRef<IDatabase>(new IndexeddbDatabase(
        async () => {
            if (indexeddb.current) {
                // Database connection is already open.
                return indexeddb.current; 
            }

            // Opens the database connection.
            indexeddb.current = await openDatabase("photosphere", databaseConfiguration);
            return indexeddb.current;
        }
    ));
    const indexeddb = useRef<IDBDatabase | undefined>(undefined);

    //
    // Closes the database connection.
    //
    function closeDatabase() {
        if (indexeddb.current) {
            indexeddb.current.close();
            indexeddb.current = undefined;
        }
    }    

    useEffect(() => {
        return () => {
            closeDatabase();
        };
    }, []);

    //
    // Deletes the local copy of the database.
    //
    async function deleteDatabase(): Promise<void> {
        closeDatabase();
        await _deleteDatabase("photosphere");
    }

    const value: IIndexeddbContext = {
        database: database.current,
        deleteDatabase,
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

