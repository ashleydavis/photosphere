import { IIndexeddbDatabase } from "../database/indexeddb/indexeddb-database";
import * as indexeddb from "../database/indexeddb/indexeddb";
import { createReverseChronoTimestamp } from "../timestamp";
import { IRecord } from "../database/database-collection";

export interface IPersistentRecord<DataT> {
    //
    // The ID of the record.
    //
    _id: string;

    //
    // Data contained in the record.
    //
    data: DataT;
}

//
// Queues updates to be sent to the server.
//
export interface IPersistentQueue<DataT> {
    //
    // Gets the next record in the queue.
    //
    getNext(): Promise<DataT | undefined>;

    //
    // Removes the next record in the queue.
    //
    removeNext(): Promise<void>;

    //
    // Adds a record to the queue.
    //
    add(data: DataT): Promise<void>;
}

//
// Queues updates to be sent to the server.
//
export class PersistentQueue<DataT> implements IPersistentQueue<DataT> {

    //
    // The key for the next record to be removed.
    //
    private key: string | undefined = undefined;

    constructor(private database: IIndexeddbDatabase, private collectionName: string) {
    }

    //
    // Gets the next record in the queue.
    //
    async getNext(): Promise<DataT | undefined> {
        const db = await this.database.getIndexedDb();
        const result = await indexeddb.getLeastRecentRecord<IPersistentRecord<DataT>>(db, this.collectionName);
        if (!result) {
            return undefined;
        }

        const [key, record] = result;
        this.key = key;
        return record.data;
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
    async add(data: DataT): Promise<void> {
        const db = await this.database.getIndexedDb();
        const _id = createReverseChronoTimestamp(new Date());
        await indexeddb.storeRecord<IPersistentRecord<DataT>>(db, this.collectionName, {
            _id,
            data,
        });
    }
}