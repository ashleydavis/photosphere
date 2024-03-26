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
    addMetadata(assetId: string, hash: string, asset: IAsset): Promise<void>;

    //
    // Gets the metadata for an asset.
    //
    getMetadata(assetId: string): Promise<IAsset | undefined>;

    //
    // Upload an original asset.
    //
    uploadOriginal(assetId: string, contentType: string, inputStream: Readable): Promise<void>;

    //
    // Streams the oirginal asset.
    //
    streamOriginal(assetId: string): Promise<IAssetStream | undefined>;

    //
    // Uploads an asset thumbnail.
    //
    uploadThumbnail(assetId: string, contentType: string, inputStream: Readable): Promise<void>;

    //
    // Streams the asset thumbnail.
    //
    streamThumbnail(assetId: string): Promise<IAssetStream | undefined>;

    //
    // Uploads the display resolution asset.
    //
    uploadDisplay(assetId: string, contentType: string, inputStream: Readable): Promise<void>;

    //
    // Streams the display resolution asset.
    //
    streamDisplay(assetId: string): Promise<IAssetStream | undefined>;

    //
    // Adds a label.
    //
    addLabel(assetId: string, label: string): Promise<void>;

    // 
    // Removes a label.
    //
    removeLabel(assetId: string, label: string): Promise<void>;

    //
    // Sets the description.
    //
    setDescription(assetId: string, description: string): Promise<void>;

    //
    // Checks if the asset exists based on a hash.
    //
    checkAsset(hash: string): Promise<string | undefined>;

    //
    // Gets the list of all assets.
    //
    getAssets(next?: string): Promise<IAssetsResult>;
}

export class AssetDatabase {

    constructor(private database: IDatabase<IAsset>, private storage: IStorage) {
    }

    //
    // Tracks a new hash to an asset id.
    //
    private async updateHash(hash: string, assetId: string): Promise<void> {
        await this.storage.write("hash", hash, "text/plain", Buffer.from(assetId));
    }

    //
    // Reads the assetId that is linked to a hash.
    //
    private async readHash(hash: string): Promise<string | undefined> {
        const buffer = await this.storage.read("hash", hash);
        if (!buffer) {
            return undefined;
        }
        return buffer.toString("utf-8");
    }

    //
    // Adds metadata for a new asset.
    //
    async addMetadata(assetId: string, hash: string, asset: IAsset): Promise<void> {
        await this.database.setOne(assetId, asset);
        await this.updateHash(hash, assetId);
    }

    //
    // Gets the metadata for an asset.
    //
    async getMetadata(assetId: string): Promise<IAsset | undefined> {
        return this.database.getOne(assetId);
    }

    //
    // Uploads an original asset.
    //
    async uploadOriginal(assetId: string, contentType: string, inputStream: Readable): Promise<void> {
        await this.storage.writeStream("original", assetId, contentType, inputStream);
    }

    //
    // Streams the original asset.
    //
    async streamOriginal(assetId: string): Promise<IAssetStream | undefined> {
        const info = await this.storage.info("original", assetId);
        if (!info) {
            return undefined;
        }

        return {
            contentType: info.contentType,
            stream: this.storage.readStream("original", assetId),
        };
    }

    //
    // Uploads an asset thumbnail.
    //
    async uploadThumbnail(assetId: string, contentType: string, inputStream: Readable): Promise<void> {
        await this.storage.writeStream("thumb", assetId, contentType, inputStream);
    }

    //
    // Streams the asset thumbnail.
    //
    async streamThumbnail(assetId: string): Promise<IAssetStream | undefined> {
        const info = await this.storage.info("thumb", assetId);
        if (!info) {
            return undefined;
        }

        return {
            contentType: info.contentType,
            stream: this.storage.readStream("thumb", assetId),
        };
    }

    //
    // Uploads the display resolution asset.
    //
    async uploadDisplay(assetId: string, contentType: string, inputStream: Readable): Promise<void> {
        await this.storage.writeStream("display", assetId, contentType, inputStream);
    }

    //
    // Streams the display resolution asset.
    //
    async streamDisplay(assetId: string): Promise<IAssetStream | undefined> {
        const info = await this.storage.info("display", assetId);
        if (!info) {
            return undefined;
        }

        return {
            contentType: info.contentType,
            stream: this.storage.readStream("display", assetId),
        };
    }

    //
    // Adds a label.
    //
    async addLabel(assetId: string, label: string): Promise<void> {
        const asset = await this.database.getOne(assetId);
        if (!asset) {
            throw new Error(`Asset ${assetId} not found.`);
        }

        if (!asset.labels) {
            asset.labels = [];
        }

        asset.labels.push(label);
        await this.database.setOne(assetId, asset);
    }

    // 
    // Removes a label.
    //
    async removeLabel(assetId: string, label: string): Promise<void> {
        const asset = await this.database.getOne(assetId);
        if (!asset) {
            throw new Error(`Asset ${assetId} not found.`);
        }

        if (asset.labels) {
            asset.labels = asset.labels.filter(l => l !== label);
            await this.database.setOne(assetId, asset);
        }
    }

    //
    // Sets the description.
    //
    async setDescription(assetId: string, description: string): Promise<void> {
        await this.database.updateOne(assetId, { description });
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
        const result = await this.storage.list("metadata", 1000, next);
        const assets = await Promise.all(result.assetIds
            .map(assetId => this.database.getOne(assetId))
        );  
        return {
            assets: assets.filter(asset => asset !== undefined) as IAsset[],
            next: result.continuation,
        };
    }

}