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
import { IAssetOps, ICollectionOps, IDbOps } from "../lib/ops";
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
// Records updates to assets in the collection.
//
export interface IJournalRecord {
    //
    // The date the server received the operation.
    //
    serverTime: string;
    
    //
    // Operations to apply to assets in the collection.
    //
    ops: IAssetOps[];
}

export interface ICollectionOpsResult {
    //
    // Operations against the collection.
    //
    collectionOps: ICollectionOps;

    //
    // The id of the latest asset that has been retreived.
    //
    latestUpdateId?: string;

    //
    // Continuation token for the next page of operations.
    //
    next?: string;
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
    applyOperations(ops: IDbOps): Promise<void>;

    //
    // Retreives operations from the database.
    //
    retreiveOperations(collectionId: string, lastUpdateId?: string): Promise<ICollectionOpsResult>;

    //
    // Retreives the latest update id for a collection.
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

    private journal: IDatabaseCollection<IJournalRecord>;
    private database: IDatabaseCollection<IAsset>;

    constructor(private storage: IStorage) {
        this.database = new DatabaseCollection<IAsset>(storage);
        this.journal = new DatabaseCollection<IJournalRecord>(storage);
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
    async applyOperations(dbOps: IDbOps): Promise<void> {

        for (const collectionOps of dbOps.ops) {
            const collectionId = collectionOps.id;

            //
            // Updates the journal for the collection.
            //
            const journalRecordId = createReverseChronoTimestamp(new Date());
            const journalRecord: IJournalRecord = {
                serverTime: dayjs().toISOString(),
                ops: collectionOps.ops,
            };
            await this.journal.setOne(`collections/${collectionId}/journal`, journalRecordId, journalRecord);

            for (const assetOps of collectionOps.ops) {
                const assetId = assetOps.id;
                const asset = await this.database.getOne(`collections/${collectionId}/metadata`, assetId);
                let fields = asset as any || {};

                if (!asset) {
                    // Set the asset id when upserting.
                    fields._id = assetId;
                }

                for (const assetOp of assetOps.ops) {
                    switch (assetOp.type) {
                        case "set": {
                            for (const [name, value] of Object.entries(assetOp.fields)) {
                                fields[name] = value;
                            }
                            break;
                        }

                        case "push": {
                            if (!fields[assetOp.field]) {
                                fields[assetOp.field] = [];
                            }
                            fields[assetOp.field].push(assetOp.value);
                            break;
                        }

                        case "pull": {
                            if (!fields[assetOp.field]) {
                                fields[assetOp.field] = [];
                            }
                            fields[assetOp.field] = fields[assetOp.field].filter((v: any) => v !== assetOp.value);
                            break;
                        }

                        default: {
                            throw new Error(`Invalid operation type: ${(assetOp as any).type}`);
                        }
                    }
                }

                await this.database.setOne(`collections/${collectionId}/metadata`, assetId, fields);
            }
        }
    }

    //
    // Retreives operations for a particular collection.
    //
    async retreiveOperations(collectionId: string, lastUpdateId: string | undefined): Promise<ICollectionOpsResult> { 
        const result = await this.journal.listAll(`collections/${collectionId}/journal`, 1000);
        let journalRecordIds = result.records;
        let cutOffIndex: number | undefined = undefined;

        //
        // Only deliver updates that are newer than the record that was last seen.
        //
        if (lastUpdateId !== undefined) {
            cutOffIndex = binarySearch(journalRecordIds, lastUpdateId);
        }

        let next: string | undefined = result.next;

        if (cutOffIndex !== undefined) {
            journalRecordIds = journalRecordIds.slice(0, cutOffIndex);
            next = undefined; // No more to retreive.
        }

        const journalRecords = await Promise.all(
            journalRecordIds
                .map(id => 
                    this.journal.getOne(`collections/${collectionId}/journal`, id)
                )
        );

        return {
            collectionOps: {
                id: collectionId,
                ops: journalRecords
                    .filter(journalRecord => journalRecord !== undefined)
                    .map(journalRecord => journalRecord!.ops)
                    .flat()
                    .reverse(), // Operations are pull out in reverse chronological order, puts them in chronological order.
            },
            latestUpdateId: journalRecordIds.length > 0 ? journalRecordIds[0] : undefined,
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