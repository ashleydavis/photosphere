import { MediaFileDatabase } from "api";
import { createStorage, loadEncryptionKeys, pathJoin } from "storage";
import { configureLog } from "../lib/log";
import pc from "picocolors";
import { exit } from "node-utils";
import path from "path";
import fs from "fs-extra";
import { log, RandomUuidGenerator } from "utils";
import { getS3Config } from "../lib/config";

export type AssetType = "original" | "display" | "thumb";

export interface IExportCommandOptions {
    //
    // The directory that contains the media file database.
    //
    db?: string;

    //
    // The directory in which to store asset database metadata.
    //
    meta?: string;

    //
    // Path to the private key file for encryption.
    //
    key?: string;

    //
    // Type of asset to export (original, display, thumb).
    //
    type?: AssetType;

    //
    // Enables verbose logging.
    //
    verbose?: boolean;

    //
    // Non-interactive mode - use defaults and command line arguments.
    //
    yes?: boolean;
}

//
// Command that exports a particular asset by ID to a specified path.
//
export async function exportCommand(assetId: string, outputPath: string, options: IExportCommandOptions): Promise<void> {
    
    await configureLog({
        verbose: options.verbose,
    });

    try {
        // Validate inputs
        if (!assetId) {
            throw new Error("Asset ID is required");
        }

        if (!outputPath) {
            throw new Error("Output path is required");
        }

        // Setup database paths
        const dbPath = options.db || process.cwd();
        const metadataPath = options.meta || path.join(dbPath, ".db");
        const keyPath = options.key;
        const assetType = options.type || "original";

        log.info(`Looking for asset ${pc.cyan(assetId)} (${pc.magenta(assetType)}) in database at ${pc.yellow(dbPath)}`);
        log.info(`Using metadata directory: ${pc.yellow(metadataPath)}`);

        // Load encryption keys if needed
        const { options: storageOptions } = await loadEncryptionKeys(keyPath, false, "source");
        const s3Config = await getS3Config();

        // Create storage instances
        const { storage: assetStorage } = createStorage(dbPath, s3Config, storageOptions);
        const { storage: metadataStorage } = createStorage(metadataPath, s3Config, storageOptions);

        // Initialize database
        const database = new MediaFileDatabase(assetStorage, metadataStorage, undefined, new RandomUuidGenerator());

        try {
            await database.load();
        } catch (error) {
            throw new Error(`Failed to load database: ${error instanceof Error ? error.message : String(error)}`);
        }

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
                    return path.join("assets", assetId);
                case "display":
                    return path.join("display", assetId);
                case "thumb":
                    return path.join("thumb", assetId);
                default:
                    return path.join("assets", assetId);
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