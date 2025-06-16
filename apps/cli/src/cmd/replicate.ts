import { MediaFileDatabase } from "api";
import { createStorage, loadEncryptionKeys, pathJoin } from "storage";
import { configureLog } from "../lib/log";
import pc from "picocolors";
import { exit, registerTerminationCallback } from "node-utils";
import { configureS3IfNeeded } from '../lib/s3-config';
import { getDirectoryForCommand } from '../lib/directory-picker';
import { ensureMediaProcessingTools } from '../lib/ensure-tools';

export interface IReplicateCommandOptions { 
    //
    // Source metadata directory override.
    //
    srcMeta?: string;

    //
    // Destination metadata directory override.
    //
    destMeta?: string;

    //
    // Path to source encryption key file.
    //
    srcKey?: string;

    //
    // Path to destination encryption key file.
    //
    destKey?: string;

    //
    // Generate encryption keys if they don't exist.
    //
    generateKey?: boolean;

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
// Command that replicates an asset database from source to destination.
//
export async function replicateCommand(srcDir: string, destDir: string, options: IReplicateCommandOptions): Promise<void> {

    configureLog({
        verbose: options.verbose,
    });

    // Ensure media processing tools are available
    await ensureMediaProcessingTools(options.yes || false);

    // Validate source directory exists
    const sourceDatabaseDir = await getDirectoryForCommand('existing', srcDir, options.yes || false);
    
    // Destination can be new or existing
    const destinationDatabaseDir = destDir;
    
    const srcMetaPath = options.srcMeta || pathJoin(sourceDatabaseDir, '.db');
    const destMetaPath = options.destMeta || pathJoin(destinationDatabaseDir, '.db');

    // Configure S3 for source
    if (!await configureS3IfNeeded(sourceDatabaseDir)) {
        await exit(1);
    }
    
    if (!await configureS3IfNeeded(srcMetaPath)) {
        await exit(1);
    }

    // Configure S3 for destination
    if (!await configureS3IfNeeded(destinationDatabaseDir)) {
        await exit(1);
    }
    
    if (!await configureS3IfNeeded(destMetaPath)) {
        await exit(1);
    }

    // Load encryption keys
    const { options: srcStorageOptions } = await loadEncryptionKeys(options.srcKey, false, "source");
    const { options: destStorageOptions } = await loadEncryptionKeys(options.destKey, options.generateKey || false, "destination");

    // Create storage instances
    const { storage: srcAssetStorage } = createStorage(sourceDatabaseDir, srcStorageOptions);        
    const { storage: srcMetadataStorage } = createStorage(srcMetaPath);
    const { storage: destAssetStorage } = createStorage(destinationDatabaseDir, destStorageOptions);        
    const { storage: destMetadataStorage } = createStorage(destMetaPath);

    // Load source database
    const sourceDatabase = new MediaFileDatabase(srcAssetStorage, srcMetadataStorage, process.env.GOOGLE_API_KEY); 

    registerTerminationCallback(async () => {
        await sourceDatabase.close();
    });    

    await sourceDatabase.load();

    console.log(pc.blue(`🔄 Replicating database from ${sourceDatabaseDir} to ${destinationDatabaseDir}`));
    console.log(pc.gray(`Source metadata: ${srcMetaPath}`));
    console.log(pc.gray(`Destination metadata: ${destMetaPath}`));

    const result = await sourceDatabase.replicate(destAssetStorage, destMetadataStorage);

    console.log();
    console.log(pc.bold(pc.blue(`📊 Replication Results`)));
    console.log();
    
    console.log(`Total files: ${pc.cyan(result.numFiles.toString())}`);
    console.log(`Copied: ${result.numCopiedFiles > 0 ? pc.green(result.numCopiedFiles.toString()) : pc.gray('0')}`);
    console.log(`Skipped (unchanged): ${result.numExistingFiles > 0 ? pc.yellow(result.numExistingFiles.toString()) : pc.gray('0')}`);
    
    console.log();
    console.log(pc.green(`✅ Replication completed successfully`));

    await exit(0);
}