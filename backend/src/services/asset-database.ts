//
// Implements the asset database.
//

import { Readable } from "stream";
import { IAsset } from "../lib/asset";
import { DatabaseCollection, IDatabaseCollection } from "./database-collection";
import { IStorage } from "./storage";
import { IAccountMetadata } from "../lib/account";

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

export interface IAssetDatabase {
    //
    // Gets account metadata.
    //
    getAccountMetadata(accountId: string): Promise<IAccountMetadata | undefined>;

    //
    // Adds metadata for a new asset.
    //
    addMetadata(accountId: string, assetId: string, hash: string, asset: IAsset): Promise<void>;

    //
    // Gets the metadata for an asset.
    //
    getMetadata(accountId: string, assetId: string): Promise<IAsset | undefined>;

    //
    // Upload an original asset.
    //
    uploadOriginal(accountId: string, assetId: string, contentType: string, inputStream: Readable): Promise<void>;

    //
    // Streams the oirginal asset.
    //
    streamOriginal(accountId: string, assetId: string): Promise<IAssetStream | undefined>;

    //
    // Uploads an asset thumbnail.
    //
    uploadThumbnail(accountId: string, assetId: string, contentType: string, inputStream: Readable): Promise<void>;

    //
    // Streams the asset thumbnail.
    //
    streamThumbnail(accountId: string, assetId: string): Promise<IAssetStream | undefined>;

    //
    // Uploads the display resolution asset.
    //
    uploadDisplay(accountId: string, assetId: string, contentType: string, inputStream: Readable): Promise<void>;

    //
    // Streams the display resolution asset.
    //
    streamDisplay(accountId: string, assetId: string): Promise<IAssetStream | undefined>;

    //
    // Adds a label.
    //
    addLabel(accountId: string, assetId: string, label: string): Promise<void>;

    // 
    // Removes a label.
    //
    removeLabel(accountId: string, assetId: string, label: string): Promise<void>;

    //
    // Sets the description.
    //
    setDescription(accountId: string, assetId: string, description: string): Promise<void>;

    //
    // Checks if the asset exists based on a hash.
    //
    checkAsset(accountId: string, hash: string): Promise<string | undefined>;

    //
    // Gets the list of all assets.
    //
    getAssets(accountId: string, next?: string): Promise<IAssetsResult>;
}

export class AssetDatabase {

    private database: IDatabaseCollection<IAsset>;

    constructor(private storage: IStorage) {
        this.database = new DatabaseCollection<IAsset>(storage);
    }

    //
    // Tracks a new hash to an asset id.
    //
    private async updateHash(accountId: string, hash: string, assetId: string): Promise<void> {
        await this.storage.write(`accounts/${accountId}/hash`, hash, "text/plain", Buffer.from(assetId));
    }

    //
    // Reads the assetId that is linked to a hash.
    //
    private async readHash(accountId: string, hash: string): Promise<string | undefined> {
        const buffer = await this.storage.read(`accounts/${accountId}/hash`, hash);
        if (!buffer) {
            return undefined;
        }
        return buffer.toString("utf-8");
    }

    //
    // Gets account metadata.
    //
    async getAccountMetadata(accountId: string): Promise<IAccountMetadata | undefined> {
        const buffer = await this.storage.read(`accounts/${accountId}`, `metadata.json`); 
        if (!buffer) {
            return undefined;
        }
        
        return JSON.parse(buffer.toString('utf-8'));
    }


    //
    // Adds metadata for a new asset.
    //
    async addMetadata(accountId: string, assetId: string, hash: string, asset: IAsset): Promise<void> {
        await this.database.setOne(`accounts/${accountId}/metadata`, assetId, asset);
        await this.updateHash(accountId, hash, assetId);
    }

    //
    // Gets the metadata for an asset.
    //
    async getMetadata(accountId: string, assetId: string): Promise<IAsset | undefined> {
        return this.database.getOne(`accounts/${accountId}/metadata`, assetId);
    }

    //
    // Uploads an original asset.
    //
    async uploadOriginal(accountId: string, assetId: string, contentType: string, inputStream: Readable): Promise<void> {
        await this.storage.writeStream(`accounts/${accountId}/original`, assetId, contentType, inputStream);
    }

    //
    // Streams the original asset.
    //
    async streamOriginal(accountId: string, assetId: string): Promise<IAssetStream | undefined> {
        const info = await this.storage.info(`accounts/${accountId}/original`, assetId);
        if (!info) {
            return undefined;
        }

        return {
            contentType: info.contentType,
            stream: this.storage.readStream(`accounts/${accountId}/original`, assetId),
        };
    }

    //
    // Uploads an asset thumbnail.
    //
    async uploadThumbnail(accountId: string, assetId: string, contentType: string, inputStream: Readable): Promise<void> {
        await this.storage.writeStream(`accounts/${accountId}/thumb`, assetId, contentType, inputStream);
    }

    //
    // Streams the asset thumbnail.
    //
    async streamThumbnail(accountId: string, assetId: string): Promise<IAssetStream | undefined> {
        const info = await this.storage.info(`accounts/${accountId}/thumb`, assetId);
        if (!info) {
            return undefined;
        }

        return {
            contentType: info.contentType,
            stream: this.storage.readStream(`accounts/${accountId}/thumb`, assetId),
        };
    }

    //
    // Uploads the display resolution asset.
    //
    async uploadDisplay(accountId: string, assetId: string, contentType: string, inputStream: Readable): Promise<void> {
        await this.storage.writeStream(`accounts/${accountId}/display`, assetId, contentType, inputStream);
    }

    //
    // Streams the display resolution asset.
    //
    async streamDisplay(accountId: string, assetId: string): Promise<IAssetStream | undefined> {
        const info = await this.storage.info(`accounts/${accountId}/display`, assetId);
        if (!info) {
            return undefined;
        }

        return {
            contentType: info.contentType,
            stream: this.storage.readStream(`accounts/${accountId}/display`, assetId),
        };
    }

    //
    // Adds a label.
    //
    async addLabel(accountId: string, assetId: string, label: string): Promise<void> {
        const asset = await this.database.getOne(`accounts/${accountId}/metadata`, assetId);
        if (!asset) {
            throw new Error(`Asset ${assetId} not found.`);
        }

        if (!asset.labels) {
            asset.labels = [];
        }

        asset.labels.push(label);
        await this.database.setOne(`accounts/${accountId}/metadata`, assetId, asset);
    }

    // 
    // Removes a label.
    //
    async removeLabel(accountId: string, assetId: string, label: string): Promise<void> {
        const asset = await this.database.getOne(`accounts/${accountId}/metadata`, assetId);
        if (!asset) {
            throw new Error(`Asset ${assetId} not found.`);
        }

        if (asset.labels) {
            asset.labels = asset.labels.filter(l => l !== label);
            await this.database.setOne(`accounts/${accountId}/metadata`, assetId, asset);
        }
    }

    //
    // Sets the description.
    //
    async setDescription(accountId: string, assetId: string, description: string): Promise<void> {
        await this.database.updateOne(`accounts/${accountId}/metadata`, assetId, { description });
    }

    //
    // Checks if the asset exists based on a hash.
    //
    async checkAsset(accountId: string, hash: string): Promise<string | undefined> {
        return this.readHash(accountId, hash);
    }

    //
    // Gets a paginated list of all assets.
    //
    async getAssets(accountId: string, next?: string): Promise<IAssetsResult> {
        const result = await this.storage.list(`accounts/${accountId}/metadata`, 1000, next);
        const assets = await Promise.all(result.assetIds
            .map(assetId => this.database.getOne(`accounts/${accountId}/metadata`, assetId))
        );  
        return {
            assets: assets.filter(asset => asset !== undefined) as IAsset[],
            next: result.continuation,
        };
    }

}