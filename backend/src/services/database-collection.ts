//
// Implements the database on top of storage.
//

import { IDatabaseOp, applyOperation } from "database";
import { IStorage } from "./storage";

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

//
// Implements a collection of records in the database.
//
export interface IDatabaseCollection<RecordT = any> {
    //
    // Sets a new record to the database.
    //
    setOne(id: string, record: RecordT): Promise<void>;

    //
    // Gets one record by id.
    //
    getOne(id: string): Promise<RecordT | undefined>;

    //
    // Updates a record in the database.
    //
    updateOne(id: string, recordUpdate: Partial<RecordT>): Promise<void>;

    //
    // Applies an operation to the database.
    //
    applyOperation(databaseOp: IDatabaseOp): Promise<void>;

    //
    // Lists all records in the database.
    //
    listAll(max: number, next?: string): Promise<IPage<string>>;

    //
    // Gets a page of records from the database.
    //
    getAll(max: number, next?: string): Promise<IPage<RecordT>>;
}

//
// Read and write the database to storage.
//
export class StorageDatabaseCollection<RecordT = any> implements IDatabaseCollection<RecordT> {

    constructor(private storage: IStorage, private path: string) {
    }

    //
    // Sets a new record to the database.
    //
    async setOne(id: string, record: RecordT): Promise<void> {
        await this.storage.write(this.path, id, "application/json", Buffer.from(JSON.stringify(record)));
    }

    //
    // Gets one record by id.
    // 
    async getOne(id: string): Promise<RecordT | undefined> {
        const buffer = await this.storage.read(this.path, id);
        if (!buffer) {
            return undefined;
        }
        
        return JSON.parse(buffer.toString('utf-8'));
    }

    // 
    // Updates a record in the database.
    //
    async updateOne(id: string, recordUpdate: Partial<RecordT>): Promise<void> {
        const buffer = await this.storage.read(this.path, id);
        const asset = JSON.parse(buffer!.toString('utf-8'));
        const updated = Object.assign({}, asset, recordUpdate);
        await this.storage.write(this.path, id, "application/json", Buffer.from(JSON.stringify(updated)));    
    }

    //
    // Applies an operation to the database.
    //
    async applyOperation(databaseOp: IDatabaseOp): Promise<void> {
        const record = await this.getOne(databaseOp.recordId);

        let updatedAsset = record as any || {};

        if (!record) {
            // Set the asset id when upserting.
            updatedAsset._id = databaseOp.recordId;
        }

        applyOperation(databaseOp.op, updatedAsset);

        await this.setOne(databaseOp.recordId, updatedAsset);
    }


    //
    // Lists all records in the database.
    //
    async listAll(max: number, next?: string): Promise<IPage<string>> {
        const listResult = await this.storage.list(this.path, max, next);
        return {
            records: listResult.assetIds,
            next: listResult.continuation,
        };
    }

    //
    // Gets a page of records from the database.
    //
    async getAll(max: number, next?: string): Promise<IPage<RecordT>> {
        const listResult = await this.storage.list(this.path, max, next);
        const records: RecordT[] = [];
        for (const assetId of listResult.assetIds) {
            records.push((await this.getOne(assetId))!);
        }
        
        return {
            records,
            next: listResult.continuation,
        };
    }
}