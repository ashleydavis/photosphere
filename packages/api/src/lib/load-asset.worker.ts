//
// Load asset worker handler - loads a single asset from database
//

import { createStorage } from "storage";
import { resolve } from "node:path";
import type { ITaskContext } from "task-queue";
import { createMediaFileDatabase, loadDatabase, streamAsset } from "./media-file-database";
import type { ILoadAssetData, ILoadAssetResult } from "./load-asset.types";

//
// Converts a stream to a buffer
//
async function streamToBuffer(stream: NodeJS.ReadableStream): Promise<Buffer> {
    return new Promise<Buffer>((resolve, reject) => {
        const chunks: Buffer[] = [];

        stream.on("data", (chunk: Buffer) => {
            chunks.push(chunk);
        });

        stream.on("end", () => {
            resolve(Buffer.concat(chunks));
        });

        stream.on("error", (error) => {
            reject(error);
        });
    });
}

//
// Handler for loading a single asset from database
//
export async function loadAssetHandler(
    data: ILoadAssetData,
    _workingDirectory: string,
    context: ITaskContext
): Promise<ILoadAssetResult> {
    const { uuidGenerator, timestampProvider } = context;
    const { assetId, assetType } = data;

    // Use hardcoded path to test database (relative to project root)
    // Resolve from current file location: packages/api/src/lib -> project root -> test/dbs/v5
    const dbDir = resolve(__dirname, "../../../../test/dbs/50-assets");
    // const dbDir = resolve(__dirname, "../../../../test/dbs/1-asset");
    // const dbDir = resolve(__dirname, "../../../../test/dbs/v5");

    // Create storage without encryption
    const { storage: assetStorage } = createStorage(dbDir, undefined, undefined);
    
    // Create database instance
    const database = createMediaFileDatabase(assetStorage, uuidGenerator, timestampProvider);
    
    // Load the database
    await loadDatabase(assetStorage, database.metadataCollection);
    
    // Stream the asset
    const assetStream = streamAsset(assetStorage, assetId, assetType);
    
    // Convert stream to buffer
    const assetBuffer = await streamToBuffer(assetStream);
    
    // Convert buffer to base64 for result transmission
    const assetDataBase64 = assetBuffer.toString("base64"); //todo: Can we return binary data?
    
    return {
        assetId,
        assetType,
        assetData: assetDataBase64,
    };
}

