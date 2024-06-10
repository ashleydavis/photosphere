import * as indexeddb from "../database/indexeddb/indexeddb";
import { createReverseChronoTimestamp } from "../timestamp";
import { IRecord } from "../database/database-collection";
import { IDatabase } from "../database/database";

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

    constructor(private database: IDatabase, private collectionName: string) {
    }

    //
    // Gets the next record in the queue.
    //
    async getNext(): Promise<DataT | undefined> {
        const result = await this.database.collection<IPersistentRecord<DataT>>(this.collectionName).getLeastRecentRecord(this.collectionName);
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
        
        await this.database.collection(this.collectionName).deleteOne(this.key);
        this.key = undefined;
    }

    //
    // Adds a record to the queue.
    //
    async add(data: DataT): Promise<void> {
        const _id = createReverseChronoTimestamp(new Date());
        await await this.database.collection<IPersistentRecord<DataT>>(this.collectionName).setOne({
            _id,
            data,
        });
    }
}