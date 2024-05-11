import { IDatabaseCollection, IDatabaseOp, IPage, applyOperation } from "database";
import { IStorage } from "./storage";

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