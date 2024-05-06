import React, { ReactNode, createContext, useContext, useEffect, useState } from "react";
import { openDatabase } from "../lib/indexeddb";

export interface IIndexeddbContext {
    //
    // The database (when open).
    //
    db: IDBDatabase | undefined;
}

const IndexeddbContext = createContext<IIndexeddbContext | undefined>(undefined);

export interface IProps {
    children: ReactNode | ReactNode[];
}

export function IndexeddbContextProvider({ children }: IProps) {

    const [db, setDb] = useState<IDBDatabase | undefined>(undefined);

    useEffect(() => {

        async function openDb() {
            const databaseName = `photosphere-test-5`;
            setDb(await openDatabase(databaseName, 1, [
                "thumb",
                "display",
                "asset",
                "hashes",
                "metadata",
                "outgoing-asset-upload",
                "outgoing-asset-update",
                "last-update-id",
                "user",
            ]));
        }

        openDb()
            .catch(err => {
                console.error(`Failed to open indexeddb:`);
                console.error(err);
            });

        return () => {
            if (db) {
                db.close();
                setDb(undefined);
            }
        };
    }, []);

    const value: IIndexeddbContext = {
        db,
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

