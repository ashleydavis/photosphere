import { IDatabaseCollection, IPage } from "../database-collection";
import { IStorage } from "../storage/storage";

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
            records: listResult.fileNames,
            next: listResult.next,
        };
    }

    //
    // Gets a page of records from the database.
    //
    async getAll(max: number, next?: string): Promise<IPage<RecordT>> {
        const listResult = await this.storage.list(this.path, max, next);
        const records: RecordT[] = [];
        for (const fileName of listResult.fileNames) {
            records.push((await this.getOne(fileName))!);
        }
        
        return {
            records,
            next: listResult.next,
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
}