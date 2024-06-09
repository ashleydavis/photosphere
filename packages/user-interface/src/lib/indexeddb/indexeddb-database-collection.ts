import { IDatabaseCollection, IRecord } from "../database-collection";
import { deleteRecord, getAllRecords, getRecord, storeRecord } from "./indexeddb";

export interface IIndexeddbDatabaseCollection<RecordT extends IRecord> extends IDatabaseCollection<RecordT> {
}

export class IndexeddbDatabaseCollection<RecordT extends IRecord> implements IIndexeddbDatabaseCollection<RecordT> {

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
    // Gets a page of records from the database.
    //
    async getAll(): Promise<RecordT[]> {
        const db = await this.openDb();
        return await getAllRecords<RecordT>(db, this.collectionName);
    }

    //
    // Deletes a database record.
    //
    async deleteOne(recordId: string): Promise<void> {
        const db = await this.openDb();
        await deleteRecord(db, this.collectionName, recordId);
    }
}