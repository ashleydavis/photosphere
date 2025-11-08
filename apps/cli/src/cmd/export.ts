import pc from "picocolors";
import { exit } from "node-utils";
import path from "path";
import fs from "fs-extra";
import { log } from "utils";
import { loadDatabase, IBaseCommandOptions } from "../lib/init-cmd";

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
export async function exportCommand(assetId: string, outputPath: string, options: IExportCommandOptions): Promise<void> {
    const assetType = options.type || "original";
    const dbPath = options.db || process.cwd();

    const { database, assetStorage } = await loadDatabase(dbPath, options, false);

    const metadataDatabase = database.getMetadataDatabase();
    const metadataCollection = metadataDatabase.collection("metadata");
    
    const asset = await metadataCollection.getOne(assetId);
    if (!asset) {
        log.error(`Asset ${assetId} not found in database.`)
        await exit(1);
        return;
    }

    // Construct the storage path based on asset type
    const getAssetStoragePath = (type: AssetType): string => {
        switch (type) {
            case "original":
                return path.join("asset", assetId);
            case "display":
                return path.join("display", assetId);
            case "thumb":
                return path.join("thumb", assetId);
            default:
                return path.join("asset", assetId);
        }
    };

    const assetStoragePath = getAssetStoragePath(assetType);
    
    // Check if the asset exists in storage
    const assetExists = await assetStorage.fileExists(assetStoragePath);    
    if (!assetExists) {
        log.error(`Asset ${assetId} not found in database.`)
        await exit(1);
        return;
    }

    // Prepare output path
    const outputDir = path.dirname(outputPath);
    await fs.ensureDir(outputDir);

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

    // Read the asset from storage and write to output
    const assetBuffer = await assetStorage.read(assetStoragePath);
    if (!assetBuffer) {
        log.error(`Asset ${assetId} not found in database.`)
        await exit(1);
        return;
    }

    await fs.writeFile(outputFilePath, assetBuffer);

    log.info(pc.green(`✓ Successfully exported ${assetType} version of asset ${assetId} to ${outputFilePath}`));

    await exit(0);
}