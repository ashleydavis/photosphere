import React, { ReactNode, createContext, useContext, useEffect, useRef, useState } from "react";
import { openDatabase as _openDatabase, storeRecord as _storeRecord, getRecord as _getRecord, getLeastRecentRecord as _getLeastRecentRecord, getAllRecords as _getAllRecords, deleteRecord as _deleteRecord, getNumRecords as _getNumRecords } from "../lib/indexeddb";

export interface IIndexeddbContext {
    //
    // Stores a record in the database.
    //
    storeRecord<RecordT>(databaseName: string, collectionName: string, record: RecordT): Promise<void>;    

    //
    // Gets a record from the database.
    //
    getRecord<RecordT>(databaseName: string, collectionName: string, recordId: string): Promise<RecordT | undefined>;

    //
    // Gets the least recent record from the database.
    //
    getLeastRecentRecord<RecordT>(databaseName: string, collectionName: string): Promise<RecordT | undefined>;

    //
    // Gets all records from the database.
    //
    getAllRecords<RecordT>(databaseName: string, collectionName: string): Promise<RecordT[]>;

    //
    // Deletes a record.
    //
    deleteRecord(databaseName: string, collectionName: string, assetId: string): Promise<void>;

    //
    // Gets the number of records in the collection.
    //
    getNumRecords(databaseName: string, collectionName: string): Promise<number>;
}

const IndexeddbContext = createContext<IIndexeddbContext | undefined>(undefined);

export interface IProps {
    children: ReactNode | ReactNode[];
}

//
// Configures a database.
//
interface IDatabaseConfiguration {
    //
    // The names of the collections in the database.
    //
    collectionNames: string[];
}

//
// Look up database configurations by name.
//
interface IDatabaseConfigurations {
    [databaseName: string]: IDatabaseConfiguration;
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
    },
    user: {    
        collectionNames: [
            "outgoing-asset-upload",
            "outgoing-asset-update",
            "last-update-id",
            "user",
        ],
    },
    debug: { // For debugging.
        collectionNames: [                 
            "updates-recieved",
            "updates-sent",
            "initial-sync-recieved",
        ],
    },     
};

//
// The version of the database.
// This need to be incremented when the schema changes.
//
const databaseVersion = 2;

export function IndexeddbContextProvider({ children }: IProps) {

    const dbCache = useRef<Map<string, IDBDatabase>>(new Map<string, IDBDatabase>());

    useEffect(() => {
        return () => {
            //
            // Close all database connections.
            //

            if (dbCache.current) {
                for (const db of dbCache.current!.values()) {
                    db.close();
                }
    
                dbCache.current!.clear();
            }
        };
    }, []);

    //
    // Opens the database.
    //
    async function openDatabase(databaseName: string): Promise<IDBDatabase> {
        if (!dbCache.current) {
            throw new Error(`Database cache not initialised.`);
        }
        
        let db = dbCache.current.get(databaseName);
        if (db) {
            return db;
        }

        const databaseNameParts = databaseName.split("-");
        if (databaseNameParts.length === 0) {
            throw new Error(`Invalid database name: "${databaseName}"`);
        }
        const baseDatabaseName = databaseNameParts[0];
        const databaseConfiguration = databaseConfigurations[baseDatabaseName];
        if (!databaseConfiguration) {
            throw new Error(`No configuration for database: "${databaseName}" (${baseDatabaseName})`);
        }

        db = await _openDatabase(`photosphere-${databaseName}`, databaseVersion, databaseConfiguration.collectionNames);
        dbCache.current.set(databaseName, db);
        return db;
    }

    //
    // Stores a record in the database.
    //
    async function storeRecord<RecordT>(databaseName: string, collectionName: string, record: RecordT): Promise<void> {
        const db = await openDatabase(databaseName);
        await _storeRecord(db, collectionName, record);
    }

    //
    // Gets a record from the database.
    //
    async function getRecord<RecordT>(databaseName: string, collectionName: string, recordId: string): Promise<RecordT | undefined> {
        const db = await openDatabase(databaseName);
        return await _getRecord(db, collectionName, recordId);
    }

    //
    // Gets the least recent record from the database.
    //
    async function getLeastRecentRecord<RecordT>(databaseName: string, collectionName: string): Promise<RecordT | undefined> {  
        const db = await openDatabase(databaseName);
        return await _getLeastRecentRecord(db, collectionName);
    }

    //
    // Gets all records from the database.
    //
    async function getAllRecords<RecordT>(databaseName: string, collectionName: string): Promise<RecordT[]> {
        const db = await openDatabase(databaseName);
        return await _getAllRecords(db, collectionName);
    }

    //
    // Deletes a record.
    //
    async function deleteRecord(databaseName: string, collectionName: string, recordId: string): Promise<void> {
        const db = await openDatabase(databaseName);
        await _deleteRecord(db, collectionName, recordId);
    }

    //
    // Gets the number of records in the collection.
    //
    async function getNumRecords(databaseName: string, collectionName: string): Promise<number> {
        const db = await openDatabase(databaseName);
        return await _getNumRecords(db, collectionName);
    }

    const value: IIndexeddbContext = {
        storeRecord,
        getRecord,
        getLeastRecentRecord,
        getAllRecords,
        deleteRecord,
        getNumRecords,
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

