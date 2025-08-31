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
    try {
        // Validate inputs
        if (!assetId) {
            throw new Error("Asset ID is required");
        }

        if (!outputPath) {
            throw new Error("Output path is required");
        }

        const assetType = options.type || "original";
        const dbPath = options.db || process.cwd();

        log.info(`Looking for asset ${pc.cyan(assetId)} (${pc.magenta(assetType)}) in database at ${pc.yellow(dbPath)}`);

        // Load the database using shared function
        const { database, assetStorage } = await loadDatabase(dbPath, options, false, true);

        // Find the asset by ID
        log.info(`Searching for asset with ID: ${pc.cyan(assetId)}`);
        const metadataDatabase = database.getMetadataDatabase();
        const metadataCollection = metadataDatabase.collection("metadata");
        
        const asset = await metadataCollection.getOne(assetId);
        if (!asset) {
            throw new Error(`Asset with ID ${assetId} not found in database`);
        }

        log.info(`Found asset: ${pc.green(asset.origFileName)}`);
        log.info(`Content type: ${asset.contentType}`);
        log.info(`Original path: ${asset.origPath || 'N/A'}`);

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
        const assetStorage_instance = database.getAssetStorage();
        const assetExists = await assetStorage_instance.fileExists(assetStoragePath);
        
        if (!assetExists) {
            throw new Error(`${assetType.charAt(0).toUpperCase() + assetType.slice(1)} asset file not found in storage at: ${assetStoragePath}`);
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

        log.info(`Exporting to: ${pc.yellow(outputFilePath)}`);

        // Read the asset from storage and write to output
        const assetBuffer = await assetStorage_instance.read(assetStoragePath);
        if (!assetBuffer) {
            throw new Error(`Failed to read asset data from storage`);
        }

        await fs.writeFile(outputFilePath, assetBuffer);

        log.info(pc.green(`✓ Successfully exported ${assetType} version of asset ${assetId} to ${outputFilePath}`));
        log.info(`File size: ${pc.cyan(assetBuffer.length.toLocaleString())} bytes`);

    } catch (error) {
        log.error(pc.red(`Export failed: ${error instanceof Error ? error.message : String(error)}`));
        await exit(1);
    }

    await exit(0);
}