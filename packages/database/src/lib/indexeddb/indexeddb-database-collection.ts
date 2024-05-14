import { get } from "http";
import { IDatabaseCollection, IPage } from "../database-collection";
import { deleteRecord, getAllKeys, getAllRecords, getLeastRecentRecord, getNumRecords, getRecord, storeRecord } from "./indexeddb";

export class IIndexeddbDatabaseCollection<RecordT> implements IDatabaseCollection<RecordT> {

    constructor(private indexedDB: IDBDatabase, private collectionName: string) {
    }

    //
    // Sets a new record to the database.
    //
    async setOne(id: string, record: RecordT): Promise<void> { //NOTE: That ID is not used in this implementation. It must be _id in the object.
        await storeRecord<RecordT>(this.indexedDB, this.collectionName, record);
    }

    //
    // Gets one record by id.
    //
    async getOne(id: string): Promise<RecordT | undefined> {
        return await getRecord<RecordT>(this.indexedDB, this.collectionName, id);
       
    }

    //
    // Lists all records in the database.
    //
    async listAll(max: number, next?: string): Promise<IPage<string>> {
        return {
            records: await getAllKeys(this.indexedDB, this.collectionName),
            next: undefined
        };
    }

    //
    // Gets a page of records from the database.
    //
    async getAll(max: number, next?: string): Promise<IPage<RecordT>> {
        return {
            records: await getAllRecords<RecordT>(this.indexedDB, this.collectionName),
            next: undefined
        };
    }

    //
    // Deletes a database record.
    //
    async deleteOne(recordId: string): Promise<void> {
        await deleteRecord(this.indexedDB, this.collectionName, recordId);
    }

    //
    // Returns true if there are no records in the collection.
    //
    async none(): Promise<boolean> {
        const numRecords = await getNumRecords(this.indexedDB, this.collectionName);
        return numRecords === 0;
    }

    // 
    // Gets the oldest record in the collection.
    //
    async getLeastRecentRecord(): Promise<RecordT | undefined> {
        return await getLeastRecentRecord<RecordT>(this.indexedDB, this.collectionName);
    }

}