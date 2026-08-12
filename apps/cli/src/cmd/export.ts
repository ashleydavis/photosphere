import pc from "picocolors";
import { exit } from "node-utils";
import path from "path";
import * as fs from "fs/promises";
import { createWriteStream } from "fs";
import { pipeline } from "stream/promises";
import { ensureDir } from "node-utils";
import { log } from "utils";
import { openLazyOriginStorage } from "node-api";
import { loadDatabase, IBaseCommandOptions, ICommandContext } from "../lib/init-cmd";

export type AssetType = "original" | "display" | "thumb";

export interface IExportCommandOptions extends IBaseCommandOptions {
    //
    // Type of asset to export (original, display, thumb).
    //
    type?: AssetType;
}

//
// Command that exports a particular asset by ID to a specified path.
//
export async function exportCommand(context: ICommandContext, assetId: string, outputPath: string, options: IExportCommandOptions): Promise<void> {
    const { uuidGenerator, timestampProvider, sessionId } = context;
    const assetType = options.type || "original";
    const dbPath = options.db || process.cwd();

    const { bsonDatabase: metadataDatabase, assetStorage: localStorage, rawAssetStorage } = await loadDatabase(dbPath, options, uuidGenerator, timestampProvider, sessionId);
    const metadataCollection = metadataDatabase.collection("metadata");

    // A partial database may have dropped this original locally because the origin holds it. Reading
    // through origin-backed storage is what fetches it back, so exporting works whether the file is
    // on this machine or only on the remote.
    const assetStorage = await openLazyOriginStorage(localStorage, rawAssetStorage);
    
    const asset = await metadataCollection.getOne(assetId);
    if (!asset) {
        log.error(`Asset ${assetId} not found in database.`)
        await exit(1);
        return;
    }

    // Construct the storage path based on asset type.
    //
    // Separated by "/", the way every other caller writes it (asset-query.ts, upload-asset.worker.ts,
    // repair.ts, list.ts). A storage path is not a filesystem path, so path.join is wrong: on Windows
    // it returned "asset\<id>" while the object had been written at "asset/<id>", so exporting out of
    // S3 looked for a key that does not exist. On Linux and macOS path.join happens to produce "/",
    // which is why this only ever failed on Windows.
    const getAssetStoragePath = (type: AssetType): string => {
        switch (type) {
            case "original":
                return `asset/${assetId}`;
            case "display":
                return `display/${assetId}`;
            case "thumb":
                return `thumb/${assetId}`;
            default:
                return `asset/${assetId}`;
        }
    };

    const assetStoragePath = getAssetStoragePath(assetType);

    // There is deliberately no existence check on the file here. A partial database does not hold
    // every original on disk: an original the origin already has may have been dropped to save
    // space, and is fetched back from the origin when it is read. An existence check only ever looks
    // locally, so it reported an evicted original as missing from the database when the record was
    // right there and the file was one read away. The read below is what decides: if the file is
    // absent locally and the origin cannot supply it, it fails and says so.

    // Prepare output path
    const outputDir = path.dirname(outputPath);
    await ensureDir(outputDir);

    // If output path is a directory, use original filename with type suffix
    const getOutputFileName = (originalName: string, type: AssetType): string => {
        if (type === "original") {
            return originalName;
        }
        
        const ext = path.extname(originalName);
        const base = path.basename(originalName, ext);
        return `${base}_${type}${ext}`;
    };

    const outputFilePath = await fs.stat(outputPath).then(stat => {
        if (stat.isDirectory()) {
            const outputFileName = getOutputFileName(asset.origFileName, assetType);
            return path.join(outputPath, outputFileName);
        }
        return outputPath;
    }).catch(() => {
        // If file doesn't exist, assume it's a file path
        return outputPath;
    });

    // Stream the asset from storage to the output file
    const assetStream = await assetStorage.readStream(assetStoragePath);
    await pipeline(assetStream, createWriteStream(outputFilePath));

    log.info(pc.green(`✓ Successfully exported ${assetType} version of asset ${assetId} to ${outputFilePath}`));

    await exit(0);
}