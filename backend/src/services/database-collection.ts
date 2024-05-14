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

    //
    // Deletes a record from the database.
    //
    async deleteOne(id: string): Promise<void> {
        await this.storage.delete(this.path, id);
    }

    //
    // Returns true if there are no records in the collection.
    //
    async none(): Promise<boolean> {
        const result = await this.getAll(1, undefined);
        return result.records.length === 0;
    }

    // 
    // Gets the oldest record in the collection.
    //
    async getLeastRecentRecord(): Promise<RecordT | undefined> {
        throw new Error("Not implemented for storage. The implementation would be too expensive.");
    }
}