//
// Implements the asset database.
//

import { Readable } from "stream";
import { IAsset } from "../lib/asset";
import { IStorage } from "database";
import { binarySearch } from "../lib/binary-search";
import { IDatabase, IDatabaseOp, IDatabaseOpRecord, IOpSelection, applyOperationToDb } from "database";

export interface IAssetStream {
    //
    // The type of the asset.
    //
    contentType: string;

    // 
    // Stream for reading the asset.
    //
    stream: Readable;
}

export interface IAssetsResult {
    //
    // List of assets.
    //
    assets: IAsset[];

    //
    // Continuation token for the next page.
    //
    next?: string;
}

//
// Records a database operation against a particular record.
//
export interface IDatabaseOpResult {
    //
    // The id of the asset to which the operation is applied.
    //
    assetId: string;

    //
    // The operation that was applied to the record.
    //
    op: IOpSelection;
}

export interface IJournalResult {
    //
    // Operations recorded against the collection.
    //
    ops: IDatabaseOpResult[];

    //
    // The id of the latest update that has been retreived.
    //
    latestUpdateId?: string;
}

export interface IAssetCollection {
    //
    // Adds metadata for a new asset.
    //
    addMetadata(assetId: string, hash: string, asset: IAsset): Promise<void>;

    //
    // Updates metadata for an asset.
    //
    updateMetadata(assetId: string, assetUpdate: Partial<IAsset>): Promise<void>;

    //
    // Applies an operation to the database.
    //
    applyOperation(databaseOp: IDatabaseOp, clientId: string): Promise<void>;

    //
    // Gets the journal of operations that have been applied to the database.
    //
    getJournal(clientId: string, lastUpdateId?: string): Promise<IJournalResult>;

    //
    // Gets the latest update id for a collection.
    //
    getLatestUpdateId(): Promise<string | undefined>;

    //
    // Gets the metadata for an asset.
    //
    getMetadata(assetId: string): Promise<IAsset | undefined>;

    //
    // Checks if the asset exists based on a hash.
    //
    checkAsset(hash: string): Promise<string | undefined>;

    //
    // Gets the list of all assets.
    //
    getAssets(next?: string): Promise<IAssetsResult>;
}

export class AssetCollection implements IAssetCollection {

    constructor(private collectionId: string, private storage: IStorage, private database: IDatabase) {
    }

    //
    // Tracks a new hash to an asset id.
    //
    private async updateHash(hash: string, assetId: string): Promise<void> {
        const hashesCollection = this.database.collection<string[]>("hashes");
        await hashesCollection.setOne(hash, [assetId]); //todo: this should update/add rather than overwrite.
    }

    //
    // Reads the assetId that is linked to a hash.
    //
    private async readHash(hash: string): Promise<string | undefined> {
        const hashesCollection = this.database.collection<string[]>("hashes");
        const assetIds =  await hashesCollection.getOne(hash);
        if (!assetIds) {
            return undefined;
        }

        if (assetIds.length === 0) {
            return undefined;
        }

        return assetIds[0]; //todo: This should return the array of assetIds.
    }

    //
    // Adds metadata for a new asset.
    //
    async addMetadata(assetId: string, hash: string, asset: IAsset): Promise<void> {
        await this.database.collection("metadata").setOne(assetId, asset);
        await this.updateHash(hash, assetId);
    }

    //
    // Updates metadata for an asset.
    //
    async updateMetadata(assetId: string, assetUpdate: Partial<IAsset>): Promise<void> {
        const metadataCollection = this.database.collection<IAsset>("metadata");
        const asset = await metadataCollection.getOne(assetId);
        if (!asset) {
            throw new Error(`Asset ${assetId} not found.`);
        }

        const updatedAsset: IAsset = { ...asset, ...assetUpdate };
        await metadataCollection.setOne(assetId, updatedAsset);
    }

    //
    // Applies an operation to the database.
    //
    async applyOperation(databaseOp: IDatabaseOp, clientId: string): Promise<void> {
        await applyOperationToDb(this.database, databaseOp, clientId);
    }

    //
    // Gets the journal of operations that have been applied to the database.
    //
    async getJournal(clientId: string, lastUpdateId?: string): Promise<IJournalResult> {

        let allRecords: IDatabaseOpRecord[] = [];
        let done = false;
        let latestUpdateId: string | undefined = undefined;
        let next: string | undefined = undefined;
        const journalCollection = this.database.collection<IDatabaseOpRecord>("journal");

        while (!done) { 
            const result = await journalCollection.listAll(1000, next);
            next = result.next;
           
            if (result.next === undefined) {
                // No more journal records to fetch.
                done = true;
            }
            
            let journalRecordIds = result.records;
            if (latestUpdateId === undefined && journalRecordIds.length > 0) {
                latestUpdateId = journalRecordIds[0];
            }
    
            //
            // Only deliver updates that are newer than the record that was last seen.
            //
            if (lastUpdateId !== undefined) {
                const cutOffIndex = binarySearch(journalRecordIds, lastUpdateId);
                if (cutOffIndex !== undefined) {
                    journalRecordIds = journalRecordIds.slice(0, cutOffIndex);
                    done = true; // We found the requested update id, no need to continue searching through the journal. 
                }
            }

            const journalRecordPromises = journalRecordIds.map(async id => {
                const assetRecord = await journalCollection.getOne(id);
                return assetRecord!; // These records should always exist, since we just looked them up.
            });

            let journalRecords = await Promise.all(journalRecordPromises);

            // Don't deliver updates that originated from the requesting client.
            journalRecords = journalRecords.filter(journalRecord => journalRecord.clientId !== clientId); 
            allRecords = allRecords.concat(journalRecords);
        }

        //
        // Operations are pulled out in reverse chronological order, this puts them in chronological order.
        //
        allRecords.reverse(); 

        return {
            ops: allRecords.map(journalRecord => {
                return {
                    assetId: journalRecord.recordId,
                    op: journalRecord.op,
                };
            }),
            latestUpdateId,
        };
    }

    //
    // Retreives the latest update id for a collection.
    //
    async getLatestUpdateId(): Promise<string | undefined> {
        const journalCollection = this.database.collection<IDatabaseOpRecord>("journal");
        const journalIdsPage = await journalCollection.listAll(1);
        if (journalIdsPage.records.length === 0) {
            return undefined;
        }

        return journalIdsPage.records[0];
    }

    //
    // Gets the metadata for an asset.
    //
    async getMetadata(assetId: string): Promise<IAsset | undefined> {
        const metadataCollection = this.database.collection<IAsset>("metadata");
        return await metadataCollection.getOne(assetId);
    }

    //
    // Checks if the asset exists based on a hash.
    //
    async checkAsset(hash: string): Promise<string | undefined> {
        return this.readHash(hash);
    }

    //
    // Gets a paginated list of all assets.
    //
    async getAssets(next?: string): Promise<IAssetsResult> {
        const metadataCollection = this.database.collection<IAsset>("metadata");
        const result = await metadataCollection.listAll(1000, next);

        const assets = await Promise.all(result.records
            .map(assetId => metadataCollection.getOne(assetId))
        );  
        return {
            assets: assets.filter(asset => asset !== undefined) as IAsset[],
            next: result.next,
        };
    }
}