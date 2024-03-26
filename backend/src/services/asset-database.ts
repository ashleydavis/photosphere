//
// Implements the asset database.
//

import { Readable } from "stream";
import { IAsset } from "../lib/asset";
import { IDatabase } from "./database";
import { IStorage } from "./storage";

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

    constructor(private database: IDatabase<IAsset>, private storage: IStorage) {
    }

    //
    // Tracks a new hash to an asset id.
    //
    private async updateHash(accountId: string, hash: string, assetId: string): Promise<void> {
        await this.storage.write(accountId, "hash", hash, "text/plain", Buffer.from(assetId));
    }

    //
    // Reads the assetId that is linked to a hash.
    //
    private async readHash(accountId: string, hash: string): Promise<string | undefined> {
        const buffer = await this.storage.read(accountId, "hash", hash);
        if (!buffer) {
            return undefined;
        }
        return buffer.toString("utf-8");
    }

    //
    // Adds metadata for a new asset.
    //
    async addMetadata(accountId: string, assetId: string, hash: string, asset: IAsset): Promise<void> {
        await this.database.setOne(accountId, assetId, asset);
        await this.updateHash(accountId, hash, assetId);
    }

    //
    // Gets the metadata for an asset.
    //
    async getMetadata(accountId: string, assetId: string): Promise<IAsset | undefined> {
        return this.database.getOne(accountId, assetId);
    }

    //
    // Uploads an original asset.
    //
    async uploadOriginal(accountId: string, assetId: string, contentType: string, inputStream: Readable): Promise<void> {
        await this.storage.writeStream(accountId, "original", assetId, contentType, inputStream);
    }

    //
    // Streams the original asset.
    //
    async streamOriginal(accountId: string, assetId: string): Promise<IAssetStream | undefined> {
        const info = await this.storage.info(accountId, "original", assetId);
        if (!info) {
            return undefined;
        }

        return {
            contentType: info.contentType,
            stream: this.storage.readStream(accountId, "original", assetId),
        };
    }

    //
    // Uploads an asset thumbnail.
    //
    async uploadThumbnail(accountId: string, assetId: string, contentType: string, inputStream: Readable): Promise<void> {
        await this.storage.writeStream(accountId, "thumb", assetId, contentType, inputStream);
    }

    //
    // Streams the asset thumbnail.
    //
    async streamThumbnail(accountId: string, assetId: string): Promise<IAssetStream | undefined> {
        const info = await this.storage.info(accountId, "thumb", assetId);
        if (!info) {
            return undefined;
        }

        return {
            contentType: info.contentType,
            stream: this.storage.readStream(accountId, "thumb", assetId),
        };
    }

    //
    // Uploads the display resolution asset.
    //
    async uploadDisplay(accountId: string, assetId: string, contentType: string, inputStream: Readable): Promise<void> {
        await this.storage.writeStream(accountId, "display", assetId, contentType, inputStream);
    }

    //
    // Streams the display resolution asset.
    //
    async streamDisplay(accountId: string, assetId: string): Promise<IAssetStream | undefined> {
        const info = await this.storage.info(accountId, "display", assetId);
        if (!info) {
            return undefined;
        }

        return {
            contentType: info.contentType,
            stream: this.storage.readStream(accountId, "display", assetId),
        };
    }

    //
    // Adds a label.
    //
    async addLabel(accountId: string, assetId: string, label: string): Promise<void> {
        const asset = await this.database.getOne(accountId, assetId);
        if (!asset) {
            throw new Error(`Asset ${assetId} not found.`);
        }

        if (!asset.labels) {
            asset.labels = [];
        }

        asset.labels.push(label);
        await this.database.setOne(accountId, assetId, asset);
    }

    // 
    // Removes a label.
    //
    async removeLabel(accountId: string, assetId: string, label: string): Promise<void> {
        const asset = await this.database.getOne(accountId, assetId);
        if (!asset) {
            throw new Error(`Asset ${assetId} not found.`);
        }

        if (asset.labels) {
            asset.labels = asset.labels.filter(l => l !== label);
            await this.database.setOne(accountId, assetId, asset);
        }
    }

    //
    // Sets the description.
    //
    async setDescription(accountId: string, assetId: string, description: string): Promise<void> {
        await this.database.updateOne(accountId, assetId, { description });
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
        const result = await this.storage.list(accountId, "metadata", 1000, next);
        const assets = await Promise.all(result.assetIds
            .map(assetId => this.database.getOne(accountId, assetId))
        );  
        return {
            assets: assets.filter(asset => asset !== undefined) as IAsset[],
            next: result.continuation,
        };
    }

}