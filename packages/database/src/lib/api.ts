import { IAsset } from "../defs/asset";
import { IAssetData } from "../defs/asset-data";
import { IDatabaseOp } from "../defs/ops";
import { IPage } from "../defs/page";
import { IUser } from "../defs/user";
import { IJournalResult } from "./get-journal";

//
// The result of the get assets request.
//
export interface IGetAssetsResult {
    //
    // Assets returned from this request.
    // Set to an empty array if no more assets.
    //
    assets: IAsset[];

    //
    // Continuation token for the next page of assets.
    // Set to undefined when no more pages.
    //
    next?: string;
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
    // Retreives the latest update id for a collection.
    //
    getLatestUpdateId(collectionId: string): Promise<string | undefined>;

    //
    // Retreives the data for an asset from the backend.
    //
    getAsset(collectionId: string, assetId: string, assetType: string): Promise<Blob>;

    //
    // Uploads an asset to the backend.
    //
    uploadSingleAsset(collectionId: string, assetId: string, assetType: string, assetData: IAssetData): Promise<void>;

    //
    // Submits database operations to the cloud.
    //
    submitOperations(ops: IDatabaseOp[]): Promise<void>;

    //
    // Gets the journal of operations that have been applied to the database.
    //
    getJournal(collectionId: string, lastUpdateId?: string): Promise<IJournalResult>;

    //
    // Sets a new record to the database.
    //
    setOne(databaseName: string, collectionName: string, id: string, record: any): Promise<void>;

    //
    // Gets one record by id.
    //
    getOne(databaseName: string, collectionName: string, id: string): Promise<any>;

    //
    // Lists all records in the database.
    //
    listAll(databaseName: string, collectionName: string, max: number, next?: string): Promise<IPage<string>>;

    //
    // Gets a page of records from the database.
    //
    getAll(databaseName: string, collectionName: string, max: number, next?: string): Promise<IPage<any>>;

    //
    // Deletes a database record.
    //
    deleteOne(databaseName: string, collectionName: string, recordId: string): Promise<void>;
}