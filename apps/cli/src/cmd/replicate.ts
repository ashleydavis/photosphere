import { MediaFileDatabase } from "api";
import { createStorage, loadEncryptionKeys, pathJoin } from "storage";
import pc from "picocolors";
import { exit, registerTerminationCallback } from "node-utils";
import { configureS3IfNeeded } from '../lib/s3-config';
import { loadDatabase, IBaseCommandOptions } from "../lib/init-cmd";
import { clearProgressMessage, writeProgress } from '../lib/terminal-utils';

export interface IReplicateCommandOptions extends IBaseCommandOptions { 
    //
    // Destination directory for replicated database.
    //
    dest: string;

    //
    // Destination metadata directory override.
    //
    destMeta?: string;

    //
    // Path to destination encryption key file.
    //
    destKey?: string;

    //
    // Generate encryption keys if they don't exist.
    //
    generateKey?: boolean;
}

//
// Command that replicates an asset database from source to destination.
//
export async function replicateCommand(options: IReplicateCommandOptions): Promise<void> {

    // Use initCmd for source database initialization
    const sourceOptions = {
        db: options.db,
        meta: options.meta,
        key: options.key,
        verbose: options.verbose,
        yes: options.yes
    };
    
    const { database: sourceDatabase, databaseDir: sourceDatabaseDir, metaPath: srcMetaPath } = await loadDatabase(options.db, sourceOptions, 'existing', false, true);
    
    // Destination can be new or existing
    const destMetaPath = options.destMeta || pathJoin(options.dest, '.db');

    // Configure S3 for destination
    if (!await configureS3IfNeeded(options.dest)) {
        await exit(1);
    }
    
    if (!await configureS3IfNeeded(destMetaPath)) {
        await exit(1);
    }

    // Load destination encryption keys
    const { options: destStorageOptions } = await loadEncryptionKeys(options.destKey, options.generateKey || false, "destination");

    // Create destination storage instances
    const { storage: destAssetStorage } = createStorage(options.dest, destStorageOptions);        
    const { storage: destMetadataStorage } = createStorage(destMetaPath);

    console.log(pc.blue(`🔄 Replicating database from ${sourceDatabaseDir} to ${options.dest}`));
    console.log(pc.gray(`Source metadata: ${srcMetaPath}`));
    console.log(pc.gray(`Destination metadata: ${destMetaPath}`));
    console.log();

    writeProgress(`Initializing replication...`);

    const result = await sourceDatabase.replicate(destAssetStorage, destMetadataStorage, (progress) => {
        const progressMessage = `🔄 Replicating | ${progress}`;
        writeProgress(progressMessage);
    });

    clearProgressMessage(); // Flush the progress message.

    console.log();
    console.log(pc.bold(pc.blue(`📊 Replication Results`)));
    console.log();
    
    console.log(`Total files imported: ${pc.cyan(result.filesImported.toString())}`);
    console.log(`Total files considered: ${pc.cyan(result.filesConsidered.toString())}`);
    console.log(`Total files copied: ${result.copiedFiles > 0 ? pc.green(result.copiedFiles.toString()) : pc.gray('0')}`);
    console.log(`Skipped (unchanged): ${result.existingFiles > 0 ? pc.yellow(result.existingFiles.toString()) : pc.gray('0')}`);
    
    console.log();
    console.log(pc.green(`✅ Replication completed successfully`));

    await exit(0);
}