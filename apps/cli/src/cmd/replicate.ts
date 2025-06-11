import { MediaFileDatabase } from "api";
import { createStorage, loadEncryptionKeys, pathJoin } from "storage";
import { log, retry } from "utils";
import { configureLog } from "../lib/log";
import pc from "picocolors";
import { exit, registerTerminationCallback } from "node-utils";
import { configureS3IfNeeded } from '../lib/s3-config';
import { getDirectoryForCommand } from '../lib/directory-picker';
import { ensureMediaProcessingTools } from '../lib/ensure-tools';
import { clearProgressMessage, writeProgress } from '../lib/terminal-utils';
import { addFile, computeHash, createTree, HashCache, saveTreeV2, traverseTree } from "adb";
import { IStorage } from "storage";
import { Readable } from "stream";

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

interface ReplicationResult {
    totalFiles: number;
    copiedFiles: number;
    skippedFiles: number;
    failedFiles: number;
    errors: string[];
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

    // Perform replication
    const result = await performReplication(
        sourceDatabase,
        srcAssetStorage,
        destAssetStorage,
        destMetadataStorage,
        options
    );

    // Display results
    displayReplicationResults(result);

    if (result.failedFiles > 0) {
        console.log();
        console.log(pc.red(`⚠️  Replication completed with ${result.failedFiles} failures`));
        if (result.errors.length > 0) {
            console.log(pc.red(`First few errors:`));
            result.errors.slice(0, 5).forEach(error => {
                console.log(`  ${pc.red('●')} ${error}`);
            });
        }
        await exit(1);
    } else {
        console.log();
        console.log(pc.green(`✅ Replication completed successfully`));
    }

    await exit(0);
}

async function performReplication(
    sourceDatabase: MediaFileDatabase,
    srcAssetStorage: IStorage,
    destAssetStorage: IStorage,
    destMetadataStorage: IStorage,
    options: IReplicateCommandOptions
): Promise<ReplicationResult> {
    
    const result: ReplicationResult = {
        totalFiles: 0,
        copiedFiles: 0,
        skippedFiles: 0,
        failedFiles: 0,
        errors: []
    };

    // Get source merkle tree
    const sourceAssetDatabase = sourceDatabase.getAssetDatabase();
    const sourceMerkleTree = sourceAssetDatabase.getMerkleTree();
    
    console.log(pc.gray(`Source tree has ${sourceMerkleTree.metadata.totalFiles} files`));

    // Initialize destination hash cache
    const destHashCache = new HashCache(destMetadataStorage, "");
    await destHashCache.load();
    
    const cacheEntries = (destHashCache as any).entryCount || 0;
    console.log(pc.gray(`Destination hash cache has ${cacheEntries} entries`));

    // Create new destination tree
    let destMerkleTree = createTree();
    
    let processedFiles = 0;
    let startTime = Date.now();
    let lastBatchTime = startTime;
    const batchSize = 1000;

    // Traverse source tree and replicate files
    await traverseTree(sourceMerkleTree, async (node) => {
        if (node.fileName && !node.isDeleted) {
            const fileName = node.fileName;
            result.totalFiles++;
            processedFiles++;

            try {
                // Check if file needs to be copied
                const destHash = destHashCache.getHash(fileName);
                const needsCopy = !destHash || !Buffer.from(destHash.hash).equals(node.hash);

                if (needsCopy) {
                    // Copy file from source to destination
                    await copyFile(fileName, srcAssetStorage, destAssetStorage, node.hash);
                    result.copiedFiles++;
                    
                    if (options.verbose) {
                        log.verbose(`Copied: ${fileName}`);
                    }
                } else {
                    result.skippedFiles++;
                    
                    if (options.verbose) {
                        log.verbose(`Skipped (unchanged): ${fileName}`);
                    }
                }

                // Add to destination tree and update hash cache
                destMerkleTree = addFile(destMerkleTree, {
                    fileName,
                    hash: node.hash,
                    length: node.size
                });

                // Update destination hash cache
                destHashCache.addHash(fileName, {
                    hash: node.hash,
                    length: node.size,
                    lastModified: new Date() // Use current time for replicated files
                });

                // Save progress periodically
                if (processedFiles % batchSize === 0) {
                    await destHashCache.save();
                    
                    const currentTime = Date.now();
                    const batchTime = (currentTime - lastBatchTime) / 1000;
                    const averageTime = (currentTime - startTime) / 1000 / (processedFiles / batchSize);
                    const memUsage = process.memoryUsage();
                    
                    writeProgress(
                        `Processed ${pc.cyan(processedFiles.toString())} files... ` +
                        `(copied: ${pc.green(result.copiedFiles.toString())}, skipped: ${pc.yellow(result.skippedFiles.toString())}) ` +
                        `(last ${batchSize}: ${batchTime.toFixed(1)}s, avg: ${averageTime.toFixed(1)}s), ` +
                        `RSS: ${pc.gray((memUsage.rss / 1024 / 1024).toFixed(1))} MB used`
                    );
                    
                    lastBatchTime = currentTime;
                }

            } catch (error) {
                result.failedFiles++;
                const errorMessage = `Failed to replicate ${fileName}: ${error instanceof Error ? error.message : String(error)}`;
                result.errors.push(errorMessage);
                log.error(errorMessage);
            }
        }
        return true; // Continue traversal
    });

    clearProgressMessage();

    // Save final destination tree and hash cache
    console.log(pc.gray(`Saving destination tree and hash cache...`));
    
    try {
        await saveTreeV2("tree.dat", destMerkleTree, destMetadataStorage);
        await destHashCache.save();
        console.log(pc.green(`✓ Saved destination metadata`));
    } catch (error) {
        const errorMessage = `Failed to save destination metadata: ${error instanceof Error ? error.message : String(error)}`;
        result.errors.push(errorMessage);
        result.failedFiles++;
        log.error(errorMessage);
    }

    return result;
}

function bufferToReadable(buffer: Buffer): Readable {
    const readable = new Readable({
        read() {
            this.push(buffer);
            this.push(null);
        }
    });
    return readable;
}

async function copyFile(
    fileName: string,
    srcStorage: IStorage,
    destStorage: IStorage,
    expectedHash: Buffer
): Promise<void> {
    
    return retry(async () => {
        // Read from source
        const sourceData = await srcStorage.read(fileName);
        if (!sourceData) {
            throw new Error(`Source file not found: ${fileName}`);
        }

        // Verify hash before writing
        const sourceStream = bufferToReadable(sourceData);
        const computedHash = await computeHash(sourceStream);
        if (!computedHash.equals(expectedHash)) {
            throw new Error(`Hash mismatch for ${fileName}: expected ${expectedHash.toString('hex')}, got ${computedHash.toString('hex')}`);
        }

        // Write to destination
        await destStorage.write(fileName, undefined, sourceData);

        // Verify write by reading back and checking hash (optional paranoid check)
        if (process.env.PARANOID_VERIFY) {
            const writtenData = await destStorage.read(fileName);
            if (!writtenData) {
                throw new Error(`Failed to verify written file: ${fileName}`);
            }
            
            const writtenStream = bufferToReadable(writtenData);
            const writtenHash = await computeHash(writtenStream);
            if (!writtenHash.equals(expectedHash)) {
                throw new Error(`Verification failed for ${fileName}: written hash ${writtenHash.toString('hex')} != expected ${expectedHash.toString('hex')}`);
            }
        }

    }); // Use default retry parameters from retry function
}

function displayReplicationResults(result: ReplicationResult): void {
    console.log();
    console.log(pc.bold(pc.blue(`📊 Replication Results`)));
    console.log();
    
    console.log(`Total files: ${pc.cyan(result.totalFiles.toString())}`);
    console.log(`Copied: ${result.copiedFiles > 0 ? pc.green(result.copiedFiles.toString()) : pc.gray('0')}`);
    console.log(`Skipped (unchanged): ${result.skippedFiles > 0 ? pc.yellow(result.skippedFiles.toString()) : pc.gray('0')}`);
    console.log(`Failed: ${result.failedFiles > 0 ? pc.red(result.failedFiles.toString()) : pc.green('0')}`);
    
    if (result.copiedFiles > 0) {
        const percentage = ((result.copiedFiles / result.totalFiles) * 100).toFixed(1);
        console.log(`Copy percentage: ${pc.cyan(`${percentage}%`)}`);
    }
}