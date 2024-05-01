//
// Implements the asset database.
//

import { Readable } from "stream";
import { IAsset } from "../lib/asset";
import { DatabaseCollection, IDatabaseCollection } from "./database-collection";
import { IStorage } from "./storage";
import { ICollectionMetadata } from "../lib/collection";

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
// An operation to apply to an asset.
//
export interface IOp {
    //
    // The type of operation:
    //  - Sets the value of a field.
    //  - Pushs a value into an array.
    //  - Pulls a value from an array.
    //
    type: "set" | "push" | "pull";
}

//
// An operation to set a field on an asset.
//
export interface ISetOp extends IOp {
    //
    // The type of operation.
    //
    type: "set";

    //
    // The field to set.
    //
    field: string;

    //
    // The value to set.
    //
    value: any;
}

//
// An operation to push a value into an array.
//
export interface IPushOp extends IOp {
    //
    // The type of operation.
    //
    type: "push";

    //
    // The field to push to.
    //
    field: string;

    //
    // The value to push.
    //
    value: any;
}

//
// An operation to pull a value from an array.
//
export interface IPullOp extends IOp {
    //
    // The type of operation.
    //
    type: "pull";

    //
    // The field to pull from.
    //
    field: string;

    //
    // The value to pull.
    //
    value: any;
}

//
// A set of operations to apply to a particular asset.
//
export interface IAssetOps {
    //
    // The id of the asset to which operations are applied.
    //
    id: string;

    //
    // Operations to apply to this asset.
    //
    ops: IOp[];
}

//
// A set of operations to apply to a particular collection.
//
export interface ICollectionOps {
    //
    // The id of the collection to which operations are applied.
    //
    id: string; 

    //
    // Operations to apply to assets in the collection.
    //
    ops: IAssetOps[];
}

//
// A set of operations to apply to the database.
//
export interface IDbOps {
    //
    // Operations to apply to collections in the database.
    //
    ops: ICollectionOps[];
}

//
// Records updates to assets in the collection.
//
export interface IJournalEntry {
    //
    // Operations to apply to assets in the collection.
    //
    ops: IAssetOps[];
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
    // Gets the metadata for an asset.
    //
    getMetadata(collectionId: string, assetId: string): Promise<IAsset | undefined>;

    //
    // Upload an original asset.
    //
    uploadOriginal(collectionId: string, assetId: string, contentType: string, inputStream: Readable): Promise<void>;

    //
    // Streams the oirginal asset.
    //
    streamOriginal(collectionId: string, assetId: string): Promise<IAssetStream | undefined>;

    //
    // Uploads an asset thumbnail.
    //
    uploadThumbnail(collectionId: string, assetId: string, contentType: string, inputStream: Readable): Promise<void>;

    //
    // Streams the asset thumbnail.
    //
    streamThumbnail(collectionId: string, assetId: string): Promise<IAssetStream | undefined>;

    //
    // Uploads the display resolution asset.
    //
    uploadDisplay(collectionId: string, assetId: string, contentType: string, inputStream: Readable): Promise<void>;

    //
    // Streams the display resolution asset.
    //
    streamDisplay(collectionId: string, assetId: string): Promise<IAssetStream | undefined>;

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

    private journal: IDatabaseCollection<IJournalEntry>;
    private database: IDatabaseCollection<IAsset>;

    constructor(private storage: IStorage) {
        this.database = new DatabaseCollection<IAsset>(storage);
        this.journal = new DatabaseCollection<IJournalEntry>(storage);
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
            await this.journal.setOne(`collections/${collectionId}/journal`, Date.now().toString(), { ops: collectionOps.ops });

            for (const assetOps of collectionOps.ops) {
                const assetId = assetOps.id;
                const asset = await this.database.getOne(`collections/${collectionId}/metadata`, assetId);
                if (!asset) {
                    throw new Error(`Asset ${assetId} not found.`);
                }

                let fields = asset as any;

                for (const assetOp of assetOps.ops) {
                    switch (assetOp.type) {
                        case "set": {
                            const setOp = assetOp as ISetOp;
                            fields[setOp.field] = setOp.value;
                            break;
                        }

                        case "push": {
                            const pushOp = assetOp as IPushOp;
                            if (!fields[pushOp.field]) {
                                fields[pushOp.field] = [];
                            }
                            fields[pushOp.field].push(pushOp.value);
                            break;
                        }

                        case "pull": {
                            const pullOp = assetOp as IPullOp;
                            if (!fields[pullOp.field]) {
                                fields[pullOp.field] = [];
                            }
                            fields[pullOp.field] = fields[pullOp.field].filter((v: any) => v !== pullOp.value);
                            break;
                        }

                        default: {
                            throw new Error(`Invalid operation type: ${assetOp.type}`);
                        }
                    }
                }

                await this.database.setOne(`collections/${collectionId}/metadata`, assetId, fields);
            }
        }
    }

    //
    // Gets the metadata for an asset.
    //
    async getMetadata(collectionId: string, assetId: string): Promise<IAsset | undefined> {
        return this.database.getOne(`collections/${collectionId}/metadata`, assetId);
    }

    //
    // Uploads an original asset.
    //
    async uploadOriginal(collectionId: string, assetId: string, contentType: string, inputStream: Readable): Promise<void> {
        await this.storage.writeStream(`collections/${collectionId}/original`, assetId, contentType, inputStream);
    }

    //
    // Streams the original asset.
    //
    async streamOriginal(collectionId: string, assetId: string): Promise<IAssetStream | undefined> {
        const info = await this.storage.info(`collections/${collectionId}/original`, assetId);
        if (!info) {
            return undefined;
        }

        return {
            contentType: info.contentType,
            stream: this.storage.readStream(`collections/${collectionId}/original`, assetId),
        };
    }

    //
    // Uploads an asset thumbnail.
    //
    async uploadThumbnail(collectionId: string, assetId: string, contentType: string, inputStream: Readable): Promise<void> {
        await this.storage.writeStream(`collections/${collectionId}/thumb`, assetId, contentType, inputStream);
    }

    //
    // Streams the asset thumbnail.
    //
    async streamThumbnail(collectionId: string, assetId: string): Promise<IAssetStream | undefined> {
        const info = await this.storage.info(`collections/${collectionId}/thumb`, assetId);
        if (!info) {
            return undefined;
        }

        return {
            contentType: info.contentType,
            stream: this.storage.readStream(`collections/${collectionId}/thumb`, assetId),
        };
    }

    //
    // Uploads the display resolution asset.
    //
    async uploadDisplay(collectionId: string, assetId: string, contentType: string, inputStream: Readable): Promise<void> {
        await this.storage.writeStream(`collections/${collectionId}/display`, assetId, contentType, inputStream);
    }

    //
    // Streams the display resolution asset.
    //
    async streamDisplay(collectionId: string, assetId: string): Promise<IAssetStream | undefined> {
        const info = await this.storage.info(`collections/${collectionId}/display`, assetId);
        if (!info) {
            return undefined;
        }

        return {
            contentType: info.contentType,
            stream: this.storage.readStream(`collections/${collectionId}/display`, assetId),
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