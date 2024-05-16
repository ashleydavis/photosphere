import { createReverseChronoTimestamp, indexeddb } from "database";

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
    // The database that contains the queue.
    //
    private db: IDBDatabase | undefined = undefined;

    //
    // The key for the next record to be removed.
    //
    private key: string | undefined = undefined


    constructor(private databaseName: string, private databaseVersion: number, private collectionName: string) {
    }

    //
    // Opens the database connection.
    //
    async open(): Promise<void> {
        if (this.db === undefined) {
            this.db = await indexeddb.openDatabase(this.databaseName, this.databaseVersion, [ this.collectionName ]);
        }        
    }

    //
    // Closes the database connection.
    //
    close(): void {
        if (this.db) {
            this.db.close();
            this.db = undefined;
        }
    }

    //
    // Gets the next record in the queue.
    //
    async getNext(): Promise<RecordT | undefined> {
        if (this.db === undefined) {
            throw new Error("Database is not open");
        }

        const result = await indexeddb.getLeastRecentRecord<RecordT>(this.db, this.collectionName);
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
        if (this.db === undefined) {
            throw new Error("Database is not open");
        }

        if (this.key === undefined) {
            throw new Error("No key to remove, call getNext first.");
        }

        await indexeddb.deleteRecord(this.db, this.collectionName, this.key);
        this.key = undefined;
    }

    //
    // Adds a record to the queue.
    //
    async add(record: RecordT): Promise<void> {
        if (this.db === undefined) {
            throw new Error("Database is not open");
        }

        const id = createReverseChronoTimestamp(new Date());
        await indexeddb.storeRecord<RecordT>(this.db, this.collectionName, id, record);
    }
}