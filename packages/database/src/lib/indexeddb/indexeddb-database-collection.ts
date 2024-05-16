import { get } from "http";
import { IDatabaseCollection, IPage } from "../database-collection";
import { deleteRecord, getAllKeys, getAllRecords, getLeastRecentRecord, getNumRecords, getRecord, storeRecord } from "./indexeddb";

export interface IIndexeddbDatabaseCollection<RecordT> extends IDatabaseCollection<RecordT> {
}

export class IndexeddbDatabaseCollection<RecordT> implements IIndexeddbDatabaseCollection<RecordT> {

    constructor(private collectionName: string, private openDb: () => Promise<IDBDatabase>) {
    }

    //
    // Sets a new record to the database.
    //
    async setOne(id: string, record: RecordT): Promise<void> {
        const db = await this.openDb();
        await storeRecord<RecordT>(db, this.collectionName, id, record);
    }

    //
    // Gets one record by id.
    //
    async getOne(id: string): Promise<RecordT | undefined> {
        const db = await this.openDb();
        return await getRecord<RecordT>(db, this.collectionName, id);
    }

    //
    // Lists all records in the database.
    //
    async listAll(max: number, next?: string): Promise<IPage<string>> {
        const db = await this.openDb();
        return {
            records: await getAllKeys(db, this.collectionName),
            next: undefined, // Indexeddb doesn't support pagination.
        };
    }

    //
    // Gets a page of records from the database.
    //
    async getAll(max: number, next?: string): Promise<IPage<RecordT>> {
        const db = await this.openDb();
        return {
            records: await getAllRecords<RecordT>(db, this.collectionName),
            next: undefined, // Indexeddb doesn't support pagination.
        };
    }

    //
    // Deletes a database record.
    //
    async deleteOne(recordId: string): Promise<void> {
        const db = await this.openDb();
        await deleteRecord(db, this.collectionName, recordId);
    }

    //
    // Returns true if there are no records in the collection.
    //
    async none(): Promise<boolean> {
        const db = await this.openDb();
        const numRecords = await getNumRecords(db, this.collectionName);
        return numRecords === 0;
    }
}