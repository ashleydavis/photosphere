//
// Implements the asset database.
//

import { Readable } from "stream";
import { IAsset } from "../lib/asset";
import { DatabaseCollection, IDatabaseCollection } from "./database-collection";
import { IStorage } from "./storage";
import { ICollectionMetadata } from "../lib/collection";
import { createReverseChronoTimestamp } from "../lib/timestamp";
import dayjs from "dayjs";
import { IAssetOp, IAssetOpRecord, IOpSelection } from "../lib/ops";
import { binarySearch } from "../lib/binary-search";

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
// Records an operation against a particular asset.
//
export interface IAssetOpResult {
    //
    // The id of the asset to which the operation is applied.
    //
    assetId: string;

    //
    // The operation that was applied to the asset.
    //
    op: IOpSelection;
}

export interface IJournalResult {
    //
    // Operations recorded against the collection.
    //
    ops: IAssetOpResult[];

    //
    // The id of the latest update that has been retreived.
    //
    latestUpdateId?: string;
}

export interface IAssetDatabase {
    //
    // Gets collection metadata.
    //
    getCollectionMetadata(collectionId: string): Promise<ICollectionMetadata | undefined>;

    //
    // Adds metadata for a new asset.
    //
    addMetadata(collectionId: string, assetId: string, hash: string, asset: IAsset): Promise<void>;

    //
    // Updates metadata for an asset.
    //
    updateMetadata(collectionId: string, assetId: string, assetUpdate: Partial<IAsset>): Promise<void>;

    //
    // Applies a set of operations to the database.
    //
    applyOperations(ops: IAssetOp[], clientId: string): Promise<void>;

    //
    // Gets the journal of operations that have been applied to the database.
    //
    getJournal(collectionId: string, clientId: string, lastUpdateId?: string): Promise<IJournalResult>;

    //
    // gETS the latest update id for a collection.
    //
    getLatestUpdateId(collectionId: string): Promise<string | undefined>;

    //
    // Gets the metadata for an asset.
    //
    getMetadata(collectionId: string, assetId: string): Promise<IAsset | undefined>;

    //
    // Upload an asset.
    //
    uploadAsset(collectionId: string, assetId: string, assetType: string, contentType: string, inputStream: Readable): Promise<void>;

    //
    // Streams am asset asset.
    //
    streamAsset(collectionId: string, assetId: string, assetType: string): Promise<IAssetStream | undefined>;

    //
    // Checks if the asset exists based on a hash.
    //
    checkAsset(collectionId: string, hash: string): Promise<string | undefined>;

    //
    // Gets the list of all assets.
    //
    getAssets(collectionId: string, next?: string): Promise<IAssetsResult>;
}

export class AssetDatabase {

    private journal: IDatabaseCollection<IAssetOpRecord>;
    private database: IDatabaseCollection<IAsset>;

    constructor(private storage: IStorage) {
        this.database = new DatabaseCollection<IAsset>(storage);
        this.journal = new DatabaseCollection<IAssetOpRecord>(storage);
    }

    //
    // Tracks a new hash to an asset id.
    //
    private async updateHash(collectionId: string, hash: string, assetId: string): Promise<void> {
        await this.storage.write(`collections/${collectionId}/hash`, hash, "text/plain", Buffer.from(assetId));
    }

    //
    // Reads the assetId that is linked to a hash.
    //
    private async readHash(collectionId: string, hash: string): Promise<string | undefined> {
        const buffer = await this.storage.read(`collections/${collectionId}/hash`, hash);
        if (!buffer) {
            return undefined;
        }
        return buffer.toString("utf-8");
    }

    //
    // Gets collection metadata.
    //
    async getCollectionMetadata(collectionId: string): Promise<ICollectionMetadata | undefined> {
        const buffer = await this.storage.read(`collections/${collectionId}`, `metadata.json`); 
        if (!buffer) {
            return undefined;
        }
        
        return JSON.parse(buffer.toString('utf-8'));
    }


    //
    // Adds metadata for a new asset.
    //
    async addMetadata(collectionId: string, assetId: string, hash: string, asset: IAsset): Promise<void> {
        await this.database.setOne(`collections/${collectionId}/metadata`, assetId, asset);
        await this.updateHash(collectionId, hash, assetId);
    }

    //
    // Updates metadata for an asset.
    //
    async updateMetadata(collectionId: string, assetId: string, assetUpdate: Partial<IAsset>): Promise<void> {
        const asset = await this.database.getOne(`collections/${collectionId}/metadata`, assetId);
        if (!asset) {
            throw new Error(`Asset ${assetId} not found.`);
        }

        const updatedAsset = { ...asset, ...assetUpdate };
        await this.database.setOne(`collections/${collectionId}/metadata`, assetId, updatedAsset);
    }

    //
    // Applies a set of operations to the database.
    //
    async applyOperations(ops: IAssetOp[], clientId: string): Promise<void> {

        for (const assetOp of ops) {
            const assetId = assetOp.assetId;
            const assetOpRecord: IAssetOpRecord = {
                serverTime: dayjs().toISOString(),
                clientId,
                assetId,
                op: assetOp.op,
            };
            
            const collectionId = assetOp.collectionId;
            const journalRecordId = createReverseChronoTimestamp(new Date());
            await this.journal.setOne(`collections/${collectionId}/journal`, journalRecordId, assetOpRecord);

            const asset = await this.database.getOne(`collections/${collectionId}/metadata`, assetId);
            let fields = asset as any || {};

            if (!asset) {
                // Set the asset id when upserting.
                fields._id = assetId;
            }

            this.applyOperation(assetOp.op, fields);

            await this.database.setOne(`collections/${collectionId}/metadata`, assetId, fields);
        }
    }

    //
    // Applies a single database operation to the field set for an asset.
    //
    private applyOperation(op: IOpSelection, fields: any): void {
        switch (op.type) {
            case "set": {
                for (const [name, value] of Object.entries(op.fields)) {
                    fields[name] = value;
                }
                break;
            }

            case "push": {
                if (!fields[op.field]) {
                    fields[op.field] = [];
                }
                fields[op.field].push(op.value);
                break;
            }

            case "pull": {
                if (!fields[op.field]) {
                    fields[op.field] = [];
                }
                fields[op.field] = fields[op.field].filter((v: any) => v !== op.value);
                break;
            }

            default: {
                throw new Error(`Invalid operation type: ${(op as any).type}`);
            }
        }
    }

    //
    // Gets the journal of operations that have been applied to the database.
    //
    async getJournal(collectionId: string, clientId: string, lastUpdateId?: string): Promise<IJournalResult> {

        let allRecords: IAssetOpRecord[] = [];
        let done = false;
        let latestUpdateId: string | undefined = undefined;
        let next: string | undefined = undefined;

        while (!done) { 
            const result = await this.journal.listAll(`collections/${collectionId}/journal`, 1000, next);
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
                const assetRecord = await this.journal.getOne(`collections/${collectionId}/journal`, id);
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
                    assetId: journalRecord.assetId,
                    op: journalRecord.op,
                };
            }),
            latestUpdateId,
        };
    }

    //
    // Retreives the latest update id for a collection.
    //
    async getLatestUpdateId(collectionId: string): Promise<string | undefined> {
        const journalIdsPage = await this.journal.listAll(`collections/${collectionId}/journal`, 1, undefined);
        if (journalIdsPage.records.length === 0) {
            return undefined;
        }

        return journalIdsPage.records[0];
    }

    //
    // Gets the metadata for an asset.
    //
    async getMetadata(collectionId: string, assetId: string): Promise<IAsset | undefined> {
        return this.database.getOne(`collections/${collectionId}/metadata`, assetId);
    }

    //
    // Uploads an asset.
    //
    async uploadAsset(collectionId: string, assetId: string, assetType: string, contentType: string, inputStream: Readable): Promise<void> {
        await this.storage.writeStream(`collections/${collectionId}/${assetType}`, assetId, contentType, inputStream);
    }

    //
    // Streams an asset.
    //
    async streamAsset(collectionId: string, assetId: string, assetType: string): Promise<IAssetStream | undefined> {
        const info = await this.storage.info(`collections/${collectionId}/${assetType}`, assetId);
        if (!info) {
            return undefined;
        }

        return {
            contentType: info.contentType,
            stream: this.storage.readStream(`collections/${collectionId}/${assetType}`, assetId),
        };
    }

    //
    // Checks if the asset exists based on a hash.
    //
    async checkAsset(collectionId: string, hash: string): Promise<string | undefined> {
        return this.readHash(collectionId, hash);
    }

    //
    // Gets a paginated list of all assets.
    //
    async getAssets(collectionId: string, next?: string): Promise<IAssetsResult> {
        const result = await this.storage.list(`collections/${collectionId}/metadata`, 1000, next);
        const assets = await Promise.all(result.assetIds
            .map(assetId => this.database.getOne(`collections/${collectionId}/metadata`, assetId))
        );  
        return {
            assets: assets.filter(asset => asset !== undefined) as IAsset[],
            next: result.continuation,
        };
    }
}