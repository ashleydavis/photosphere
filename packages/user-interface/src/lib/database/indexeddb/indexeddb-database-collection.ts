import { IDatabaseCollection, IRecord } from "../database-collection";
import { deleteRecord, getAllByIndex, getAllRecords, getLeastRecentRecord, getRecord, storeRecord } from "./indexeddb";

export class IndexeddbDatabaseCollection<RecordT extends IRecord> implements IDatabaseCollection<RecordT> {

    constructor(private collectionName: string, private openDb: () => Promise<IDBDatabase>) {
    }

    //
    // Sets a new record in the database.
    //
    async setOne(record: RecordT): Promise<void> {
        const db = await this.openDb();
        await storeRecord<RecordT>(db, this.collectionName, record);
    }

    //
    // Gets one record by id.
    //
    async getOne(id: string): Promise<RecordT | undefined> {
        const db = await this.openDb();
        return await getRecord<RecordT>(db, this.collectionName, id);
    }

    //
    // Gets a page of records from the database.
    //
    async getAll(): Promise<RecordT[]> {
        const db = await this.openDb();
        return await getAllRecords<RecordT>(db, this.collectionName);
    }

    //
    // Gets records from the database that match the requested index.
    //
    async getAllByIndex(indexName: string, indexValue: any): Promise<RecordT[]> {
        const db = await this.openDb();
        return await getAllByIndex<RecordT>(db, this.collectionName, indexName, indexValue);
    }

    //
    // Gets the least recent record from the database.
    // This relies on the ids being timestamps in reverse chronological order.
    //
    async getLeastRecentRecord(collectionName: string): Promise<[string, RecordT] | undefined> {
        const db = await this.openDb();
        return await getLeastRecentRecord<RecordT>(db, collectionName);
    }

    //
    // Deletes a database record.
    //
    async deleteOne(recordId: string): Promise<void> {
        const db = await this.openDb();
        await deleteRecord(db, this.collectionName, recordId);
    }
}