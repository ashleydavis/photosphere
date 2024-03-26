//
// Implements the database on top of storage.
//

import { IStorage } from "./storage";

export interface IAssetOps {
    //
    // The record to perform operations on.
    //
    id: string;

    //
    // Operations to apply to the record.
    //
    ops: [
        {
            //
            // The operation to perform.
            //
            op: string;

            //
            // The value to apply to the operation.
            //
            data: any;
        },
    ],
};

//
// A page of records from the database.
//
export interface IPage<RecordT> {
    //
    // Array of records in the page.
    //
    records: RecordT[];

    //
    // Continuation token for the next page.
    //
    next?: string;
}

export interface IDatabase<RecordT = any> {
    //
    // Sets a new record to the database.
    //
    setOne(accountId: string, id: string, record: RecordT): Promise<void>;

    //
    // Gets one record by id.
    //
    getOne(accountId: string, id: string): Promise<RecordT | undefined>;

    //
    // Updates a record in the database.
    //
    updateOne(accountId: string, id: string, recordUpdate: Partial<RecordT>): Promise<void>;

    //
    // Gets a page of records from the database.
    //
    getAll(accountId: string, max: number, next?: string): Promise<IPage<RecordT>>;
}

export class Database<RecordT = any> implements IDatabase<RecordT> {

    constructor(private storage: IStorage) {
    }

    //
    // Sets a new record to the database.
    //
    async setOne(accountId: string, id: string, record: RecordT): Promise<void> {
        await this.storage.write(accountId, "metadata", id, "application/json", Buffer.from(JSON.stringify(record)));
    }

    //
    // Gets one record by id.
    // 
    async getOne(accountId: string, id: string): Promise<RecordT | undefined> {
        const buffer = await this.storage.read(accountId, "metadata", id);
        if (!buffer) {
            return undefined;
        }
        
        return JSON.parse(buffer.toString('utf-8'));
    }

    // 
    // Updates a record in the database.
    //
    async updateOne(accountId: string, id: string, recordUpdate: Partial<RecordT>): Promise<void> {
        const buffer = await this.storage.read(accountId, "metadata", id);
        const asset = JSON.parse(buffer!.toString('utf-8'));
        const updated = Object.assign({}, asset, recordUpdate);
        await this.storage.write(accountId, "metadata", id, "application/json", Buffer.from(JSON.stringify(updated)));    
    }

    //
    // Gets a page of records from the database.
    //
    async getAll(accountId: string, max: number, next?: string): Promise<IPage<RecordT>> {
        const listResult = await this.storage.list(accountId, "metadata", max, next);
        const records: RecordT[] = [];
        for (const assetId of listResult.assetIds) {
            records.push((await this.getOne(accountId, assetId))!);
        }
        
        return {
            records,
            next: listResult.continuation,
        };
    }
}