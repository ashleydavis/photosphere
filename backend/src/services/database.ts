import dayjs from "dayjs";
import { IDatabaseOp, IDatabaseOpRecord } from "../lib/ops";
import { IDatabaseCollection, StorageDatabaseCollection } from "./database-collection";
import { IStorage } from "./storage";
import { StorageDirectory } from "./storage-directory";
import { createReverseChronoTimestamp } from "../lib/timestamp";
import { IAsset } from "../lib/asset";

//
// Implements a database.
//
export interface IDatabase {

    //
    // Gets a database collection by name.
    //
    collection<RecordT>(name: string): IDatabaseCollection<RecordT>;

    //
    // Applies an operation to the database.
    //
    applyOperation(databaseOp: IDatabaseOp, clientId: string): Promise<void>;
}

//
// Implements a database on file storage.
//
export class StorageDatabase implements IDatabase {

    private storage: IStorage;

    constructor(storage: IStorage, path?: string) {
        if (path) {
            this.storage = new StorageDirectory(storage, path);
        }
        else {
            this.storage = storage;
        }
    }

    //
    // Gets a database collection by name.
    //
    collection<RecordT>(collectionName: string): IDatabaseCollection<RecordT> {
        return new StorageDatabaseCollection<RecordT>(this.storage, collectionName);
    }

    //
    // Applies an operation to the database.
    //
    async applyOperation(databaseOp: IDatabaseOp, clientId: string): Promise<void> {
        const databaseOpRecord: IDatabaseOpRecord = {
            serverTime: dayjs().toISOString(),
            clientId,
            collectionName: databaseOp.collectionName,
            recordId: databaseOp.recordId,
            op: databaseOp.op,
        };
        
        const journalRecordId = createReverseChronoTimestamp(new Date());
        const journalCollection = this.collection<IDatabaseOpRecord>("journal");
        await journalCollection.setOne(journalRecordId, databaseOpRecord);

        const recordCollection = this.collection(databaseOp.collectionName);
        await recordCollection.applyOperation(databaseOp);
    }    
}