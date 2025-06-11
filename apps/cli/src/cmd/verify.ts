import { MediaFileDatabase, FileScanner } from "api";
import { createStorage, loadEncryptionKeys, pathJoin } from "storage";
import { log } from "utils";
import { configureLog } from "../lib/log";
import pc from "picocolors";
import { exit, registerTerminationCallback } from "node-utils";
import { configureS3IfNeeded } from '../lib/s3-config';
import { getDirectoryForCommand } from '../lib/directory-picker';
import { ensureMediaProcessingTools } from '../lib/ensure-tools';
import { clearProgressMessage, writeProgress } from '../lib/terminal-utils';
import { computeHash, traverseTree } from "adb";
import { Readable } from "stream";
import fs from "fs";
import path from "path";

export interface IVerifyCommandOptions { 
    //
    // Set the path to the database metadata.
    //
    meta?: string;

    //
    // Sets the path to private key file for encryption.
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

    //
    // Force full verification (bypass cached hash optimization).
    //
    full?: boolean;

    //
    // Write verification summary to JSON file.
    //
    output?: string;
}

interface VerificationResult {
    totalFiles: number;
    unmodified: number;
    modified: string[];
    new: string[];
    removed: string[];
}

//
// Command that verifies the integrity of the Photosphere media file database.
//
export async function verifyCommand(dbDir: string, filePath: string | undefined, options: IVerifyCommandOptions): Promise<void> {

    configureLog({
        verbose: options.verbose,
    });

    // Ensure media processing tools are available
    await ensureMediaProcessingTools(options.yes || false);

    // Get the directory for the database (validates it exists and is a media database)
    const databaseDir = await getDirectoryForCommand('existing', dbDir, options.yes || false);
    
    const metaPath = options.meta || pathJoin(databaseDir, '.db');

    //
    // Configure S3 if the path requires it
    //
    if (!await configureS3IfNeeded(databaseDir)) {
        await exit(1);
    }
    
    if (!await configureS3IfNeeded(metaPath)) {
        await exit(1);
    }

    const { options: storageOptions } = await loadEncryptionKeys(options.key, false, "source");

    const { storage: assetStorage } = createStorage(databaseDir, storageOptions);        
    const { storage: metadataStorage } = createStorage(metaPath);

    const database = new MediaFileDatabase(assetStorage, metadataStorage, process.env.GOOGLE_API_KEY); 

    registerTerminationCallback(async () => {
        await database.close();
    });    

    await database.load();

    const result: VerificationResult = {
        totalFiles: 0,
        unmodified: 0,
        modified: [],
        new: [],
        removed: []
    };

    if (filePath) {
        // Verify single file
        await verifySingleFile(database, assetStorage, filePath, options, result);
    } else {
        // Verify entire database
        await verifyDatabase(database, assetStorage, options, result);
    }

    // Display results
    displayResults(result);

    // Write JSON summary if requested
    if (options.output) {
        await writeJsonSummary(result, options.output);
    }

    await exit(0);
}

async function verifySingleFile(
    database: MediaFileDatabase, 
    assetStorage: any, 
    filePath: string, 
    options: IVerifyCommandOptions,
    result: VerificationResult
): Promise<void> {
    
    console.log(pc.blue(`🔍 Verifying single file: ${filePath}`));
    
    const absolutePath = path.resolve(filePath);
    
    try {
        // Check if file exists
        const stats = await fs.promises.stat(absolutePath);
        const fileInfo = {
            length: stats.size,
            lastModified: stats.mtime,
            contentType: 'application/octet-stream'
        };

        // Get hash from cache
        const assetDatabase = database.getAssetDatabase();
        const hashCache = (database as any).databaseHashCache; // Access hash cache
        const cachedEntry = hashCache.getHash(filePath);

        if (!cachedEntry) {
            result.new.push(filePath);
            log.info(pc.yellow(`File not found in database: ${filePath}`));
        } else {
            // Check if file has changed or if full verification is requested
            if (options.full || 
                fileInfo.length !== cachedEntry.length || 
                fileInfo.lastModified.getTime() !== cachedEntry.lastModified.getTime()) {
                
                writeProgress(`Computing hash for: ${filePath}`);
                
                // Compute fresh hash
                const fileStream = fs.createReadStream(absolutePath);
                const computedHash = await computeHash(fileStream);
                
                if (computedHash.equals(cachedEntry.hash)) {
                    result.unmodified++;
                    log.info(pc.green(`✓ File verified: ${filePath}`));
                } else {
                    result.modified.push(filePath);
                    log.info(pc.red(`✗ File modified: ${filePath}`));
                }
            } else {
                result.unmodified++;
                log.info(pc.green(`✓ File verified (cached): ${filePath}`));
            }
        }
        
        result.totalFiles = 1;
        
    } catch (error) {
        log.error(pc.red(`Error verifying file ${filePath}: ${error}`));
        await exit(1);
    }
    
    clearProgressMessage();
}

async function verifyDatabase(
    database: MediaFileDatabase, 
    assetStorage: any, 
    options: IVerifyCommandOptions,
    result: VerificationResult
): Promise<void> {
    
    console.log(pc.blue(`🔍 Verifying database integrity`));
    
    const assetDatabase = database.getAssetDatabase();
    const merkleTree = assetDatabase.getMerkleTree();
    const hashCache = (database as any).databaseHashCache; // Access hash cache
    
    console.log(pc.gray(`Hash cache has ${(hashCache as any).entryCount || 0} entries`));
    
    let processedFiles = 0;
    let startTime = Date.now();
    let lastBatchTime = startTime;
    const batchSize = 1000;
    
    // Phase 1: Scan filesystem and verify files
    const fileScanner = new FileScanner(assetStorage);
    const scannedFiles = new Set<string>();
    
    await fileScanner.scanPaths(["."], async (fileResult) => {
        const relativePath = fileResult.filePath;
        scannedFiles.add(relativePath);
        
        // Get cached hash entry
        const cachedEntry = hashCache.getHash(relativePath);
        
        if (!cachedEntry) {
            result.new.push(relativePath);
        } else {
            // Check if file has changed or if full verification is requested
            if (options.full || 
                fileResult.fileInfo.length !== cachedEntry.length || 
                fileResult.fileInfo.lastModified.getTime() !== cachedEntry.lastModified.getTime()) {
                
                // Compute fresh hash
                const fileStream = fileResult.openStream ? fileResult.openStream() : fs.createReadStream(fileResult.filePath);
                const computedHash = await computeHash(fileStream);
                
                if (computedHash.equals(cachedEntry.hash)) {
                    result.unmodified++;
                } else {
                    result.modified.push(relativePath);
                }
            } else {
                result.unmodified++;
            }
        }
        
        processedFiles++;
        result.totalFiles++;
        
        // Progress reporting
        if (processedFiles % batchSize === 0) {
            const currentTime = Date.now();
            const batchTime = (currentTime - lastBatchTime) / 1000;
            const averageTime = (currentTime - startTime) / 1000 / (processedFiles / batchSize);
            const memUsage = process.memoryUsage();
            
            writeProgress(
                `Processed ${pc.cyan(processedFiles.toString())} files... ` +
                `(last ${batchSize}: ${batchTime.toFixed(1)}s, avg: ${averageTime.toFixed(1)}s), ` +
                `RSS: ${pc.gray((memUsage.rss / 1024 / 1024).toFixed(1))} MB used`
            );
            
            lastBatchTime = currentTime;
        }
        
    }, (currentlyScanning) => {
        if (processedFiles % batchSize !== 0) {
            writeProgress(
                `Processed ${pc.cyan(processedFiles.toString())} files... ` +
                `Scanning ${pc.yellow(currentlyScanning || 'unknown')} | ` +
                `${pc.gray("Abort with Ctrl-C")}`
            );
        }
    });
    
    // Phase 2: Check for removed files by traversing merkle tree
    let removedFileCount = 0;
    await traverseTree(merkleTree, async (node) => {
        if (node.fileName && !node.isDeleted) {
            if (!scannedFiles.has(node.fileName)) {
                result.removed.push(node.fileName);
                removedFileCount++;
            }
        }
        return true; // Continue traversal
    });
    
    clearProgressMessage();
    
    if (removedFileCount > 0) {
        console.log(pc.yellow(`Found ${removedFileCount} files in tree that are missing from filesystem`));
    }
}

function displayResults(result: VerificationResult): void {
    console.log();
    console.log(pc.bold(pc.blue(`📊 Verification Results`)));
    console.log();
    
    console.log(`Total files: ${pc.cyan(result.totalFiles.toString())}`);
    console.log(`Unmodified: ${pc.green(result.unmodified.toString())}`);
    console.log(`Modified: ${result.modified.length > 0 ? pc.red(result.modified.length.toString()) : pc.green('0')}`);
    console.log(`New: ${result.new.length > 0 ? pc.yellow(result.new.length.toString()) : pc.green('0')}`);
    console.log(`Removed: ${result.removed.length > 0 ? pc.red(result.removed.length.toString()) : pc.green('0')}`);
    
    // Show details for problematic files
    if (result.modified.length > 0) {
        console.log();
        console.log(pc.red(`Modified files:`));
        result.modified.slice(0, 10).forEach(file => {
            console.log(`  ${pc.red('●')} ${file}`);
        });
        if (result.modified.length > 10) {
            console.log(pc.gray(`  ... and ${result.modified.length - 10} more`));
        }
    }
    
    if (result.new.length > 0) {
        console.log();
        console.log(pc.yellow(`New files:`));
        result.new.slice(0, 10).forEach(file => {
            console.log(`  ${pc.yellow('+')} ${file}`);
        });
        if (result.new.length > 10) {
            console.log(pc.gray(`  ... and ${result.new.length - 10} more`));
        }
    }
    
    if (result.removed.length > 0) {
        console.log();
        console.log(pc.red(`Removed files:`));
        result.removed.slice(0, 10).forEach(file => {
            console.log(`  ${pc.red('-')} ${file}`);
        });
        if (result.removed.length > 10) {
            console.log(pc.gray(`  ... and ${result.removed.length - 10} more`));
        }
    }
    
    console.log();
    if (result.modified.length === 0 && result.new.length === 0 && result.removed.length === 0) {
        console.log(pc.green(`✅ Database verification passed - all files are intact`));
    } else {
        console.log(pc.yellow(`⚠️  Database verification found issues - see details above`));
    }
}

async function writeJsonSummary(result: VerificationResult, outputPath: string): Promise<void> {
    try {
        const summary = {
            timestamp: new Date().toISOString(),
            totalFiles: result.totalFiles,
            unmodified: result.unmodified,
            modified: result.modified,
            new: result.new,
            removed: result.removed
        };
        
        await fs.promises.writeFile(outputPath, JSON.stringify(summary, null, 2));
        console.log(pc.gray(`Summary written to: ${outputPath}`));
    } catch (error) {
        log.error(pc.red(`Failed to write summary to ${outputPath}: ${error}`));
    }
}