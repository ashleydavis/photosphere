import { IDatabaseOp } from "defs";
import { IRecord } from "./database-collection";
import { IUser } from "../def/user";
import { IAssetData } from "../def/asset-data";

//
// The result of get the database journal.
//
export interface IJournalResult {
    //
    // Operations recorded against the collection.
    //
    journalRecords: IDatabaseOp[];

    //
    // The id of the latest update that has been retreived.
    //
    latestTime: string;
}

//
// Client-side interface to the Photosphere API.
//
export interface IApi {

    //
    // Set to true once the api is ready to use.
    //
    isInitialised: boolean;

    //
    // Loads the user's details.
    //
    getUser(): Promise<IUser>;

    //
    // Retreives the latest time for the server.
    //
    getLatestTime(): Promise<string | undefined>;

    //
    // Retreives the data for an asset from the backend.
    //
    getAsset(setId: string, assetId: string, assetType: string): Promise<Blob>;

    //
    // Uploads an asset to the backend.
    //
    uploadSingleAsset(setId: string, assetId: string, assetType: string, assetData: IAssetData): Promise<void>;

    //
    // Submits database operations to the cloud.
    //
    submitOperations(ops: IDatabaseOp[]): Promise<void>;

    //
    // Gets the journal of operations that have been applied to the database.
    //
    getJournal(lastUpdateTime?: string): Promise<IJournalResult>;

    //
    // Gets one record by id.
    //
    getOne<RecordT extends IRecord>(collectionName: string, id: string): Promise<RecordT>;

    //
    // Gets a page of records from the database.
    //
    getAll<RecordT extends IRecord>(setId: string, collectionName: string, skip: number, limit: number): Promise<RecordT[]>;
}