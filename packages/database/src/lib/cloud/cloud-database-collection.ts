import { get } from "http";
import { IDatabaseCollection } from "../database-collection";
import { IApi } from "../api";
import { IPage } from "../../defs/page";

export interface ICloudDatabaseCollection<RecordT> extends IDatabaseCollection<RecordT> {
}

export class CloudDatabaseCollection<RecordT> implements ICloudDatabaseCollection<RecordT> {

    constructor(private databaseName: string, private collectionName: string, private api: IApi) {
    }

    //
    // Sets a new record to the database.
    //
    async setOne(recordId: string, record: RecordT): Promise<void> {
        await this.api.setOne(this.databaseName, this.collectionName, recordId, record);
    }

    //
    // Gets one record by id.
    //
    async getOne(recordId: string): Promise<RecordT | undefined> {
        return await this.api.getOne(this.databaseName, this.collectionName, recordId);
    }

    //
    // Lists all records in the database.
    //
    async listAll(max: number, next?: string): Promise<IPage<string>> {
        return await this.api.listAll(this.databaseName, this.collectionName, max, next);
    }

    //
    // Gets a page of records from the database.
    //
    async getAll(max: number, next?: string): Promise<IPage<RecordT>> {
        return await this.api.getAll(this.databaseName, this.collectionName, max, next);
    }

    //
    // Deletes a database record.
    //
    async deleteOne(recordId: string): Promise<void> {
        await this.api.deleteOne(this.databaseName, this.collectionName, recordId);
    }

    //
    // Returns true if there are no records in the collection.
    //
    async none(): Promise<boolean> {
        throw new Error("Not implemented.");
    }
}