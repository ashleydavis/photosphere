import { MediaFileDatabase } from "api";
import { createStorage, loadEncryptionKeys } from "storage";
import { configureLog } from "../lib/log";
import pc from "picocolors";
import { exit } from "node-utils";
import path from "path";
import { log, RandomUuidGenerator } from "utils";
import { getS3Config } from "../lib/config";

export interface IRemoveCommandOptions {
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
    // Enables verbose logging.
    //
    verbose?: boolean;

    //
    // Non-interactive mode - use defaults and command line arguments.
    //
    yes?: boolean;
}

//
// Command that removes a particular asset by ID from the database.
//
export async function removeCommand(assetId: string, options: IRemoveCommandOptions): Promise<void> {
    
    await configureLog({
        verbose: options.verbose,
    });

    try {
        // Validate inputs
        if (!assetId) {
            throw new Error("Asset ID is required");
        }

        // Setup database paths
        const dbPath = options.db || process.cwd();
        const metadataPath = options.meta || path.join(dbPath, ".db");
        const keyPath = options.key;

        log.info(`Removing asset ${pc.cyan(assetId)} from database at ${pc.yellow(dbPath)}`);
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

        // Remove the asset using the comprehensive removal method
        log.info(`Removing asset with ID: ${pc.cyan(assetId)}`);
        await database.remove(assetId);

        // Save the updated database
        await database.close();

        log.info(pc.green(`✓ Successfully removed asset ${assetId} from database`));

    } catch (error) {
        log.error(pc.red(`Remove failed: ${error instanceof Error ? error.message : String(error)}`));
        await exit(1);
    }

    await exit(0);
}