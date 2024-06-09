import { IIndexeddbDatabase } from "../database/indexeddb/indexeddb-database";
import * as indexeddb from "../database/indexeddb/indexeddb";
import { createReverseChronoTimestamp } from "../timestamp";

//
// Queues updates to be sent to the server.
//
export interface IPersistentQueue<RecordT> {
    //
    // Gets the next record in the queue.
    //
    getNext(): Promise<RecordT | undefined>;

    //
    // Removes the next record in the queue.
    //
    removeNext(): Promise<void>;

    //
    // Adds a record to the queue.
    //
    add(record: RecordT): Promise<void>;
}

//
// Queues updates to be sent to the server.
//
export class PersistentQueue<RecordT> implements IPersistentQueue<RecordT> {

    //
    // The key for the next record to be removed.
    //
    private key: string | undefined = undefined;

    constructor(private database: IIndexeddbDatabase, private collectionName: string) {
    }

    //
    // Gets the next record in the queue.
    //
    async getNext(): Promise<RecordT | undefined> {
        const db = await this.database.getIndexedDb();
        const result = await indexeddb.getLeastRecentRecord<RecordT>(db, this.collectionName);
        if (!result) {
            return undefined;
        }

        const [key, record] = result;
        this.key = key;
        return record;      
    }

    //
    // Removes the next record in the queue.
    //
    async removeNext(): Promise<void> {
       
        if (this.key === undefined) {
            throw new Error("No key to remove, call getNext first.");
        }
        
        const db = await this.database.getIndexedDb();
        await indexeddb.deleteRecord(db, this.collectionName, this.key);
        this.key = undefined;
    }

    //
    // Adds a record to the queue.
    //
    async add(record: RecordT): Promise<void> {
        const db = await this.database.getIndexedDb();
        const id = createReverseChronoTimestamp(new Date());
        await indexeddb.storeRecord<RecordT>(db, this.collectionName, id, record);
    }
}