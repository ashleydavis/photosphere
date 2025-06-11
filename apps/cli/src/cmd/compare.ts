import { MediaFileDatabase } from "api";
import { createStorage, loadEncryptionKeys, pathJoin } from "storage";
import { log } from "utils";
import { configureLog } from "../lib/log";
import pc from "picocolors";
import { exit, registerTerminationCallback } from "node-utils";
import { configureS3IfNeeded } from '../lib/s3-config';
import { getDirectoryForCommand } from '../lib/directory-picker';
import { ensureMediaProcessingTools } from '../lib/ensure-tools';
import { compareTrees } from "adb";
import fs from "fs";

export interface ICompareCommandOptions { 
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
    // Enables verbose logging.
    //
    verbose?: boolean;

    //
    // Non-interactive mode - use defaults and command line arguments.
    //
    yes?: boolean;

    //
    // Write comparison results to JSON file.
    //
    output?: string;
}

interface ComparisonResult {
    treesMatch: boolean;
    message: string;
    differences: {
        filesOnlyInA: string[];
        filesOnlyInB: string[];
        modifiedFiles: string[];
        deletedFiles: string[];
    };
    metrics: {
        filesInTreeA: number;
        filesInTreeB: number;
        totalDifferences: number;
    };
}

//
// Command that compares two asset databases by analyzing their Merkle trees.
//
export async function compareCommand(srcDir: string, destDir: string, options: ICompareCommandOptions): Promise<void> {

    configureLog({
        verbose: options.verbose,
    });

    // Ensure media processing tools are available
    await ensureMediaProcessingTools(options.yes || false);

    // Validate source and destination directories exist
    const sourceDatabaseDir = await getDirectoryForCommand('existing', srcDir, options.yes || false);
    const destinationDatabaseDir = await getDirectoryForCommand('existing', destDir, options.yes || false);
    
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
    const { options: destStorageOptions } = await loadEncryptionKeys(options.destKey, false, "destination");

    // Create storage instances
    const { storage: srcAssetStorage } = createStorage(sourceDatabaseDir, srcStorageOptions);        
    const { storage: srcMetadataStorage } = createStorage(srcMetaPath);
    const { storage: destAssetStorage } = createStorage(destinationDatabaseDir, destStorageOptions);        
    const { storage: destMetadataStorage } = createStorage(destMetaPath);

    // Load source database
    const sourceDatabase = new MediaFileDatabase(srcAssetStorage, srcMetadataStorage, process.env.GOOGLE_API_KEY); 
    const destinationDatabase = new MediaFileDatabase(destAssetStorage, destMetadataStorage, process.env.GOOGLE_API_KEY);

    registerTerminationCallback(async () => {
        await sourceDatabase.close();
        await destinationDatabase.close();
    });    

    console.log(pc.blue(`🔄 Comparing databases`));
    console.log(pc.gray(`Source: ${sourceDatabaseDir}`));
    console.log(pc.gray(`Destination: ${destinationDatabaseDir}`));

    try {
        await sourceDatabase.load();
        await destinationDatabase.load();
    } catch (error) {
        console.log(pc.red(`Error loading databases: ${error instanceof Error ? error.message : String(error)}`));
        await exit(1);
    }

    // Perform comparison
    const result = await performComparison(sourceDatabase, destinationDatabase, sourceDatabaseDir, destinationDatabaseDir);

    // Display results
    displayComparisonResults(result);

    // Write JSON output if requested
    if (options.output) {
        await writeJsonResults(result, options.output);
    }

    // Exit with appropriate code
    if (result.treesMatch) {
        console.log();
        console.log(pc.green(`✅ Databases are identical`));
        await exit(0);
    } else {
        console.log();
        console.log(pc.yellow(`⚠️  Databases have ${result.metrics.totalDifferences} differences`));
        await exit(0); // Not an error, just differences found
    }
}

async function performComparison(
    sourceDatabase: MediaFileDatabase,
    destinationDatabase: MediaFileDatabase,
    sourcePath: string,
    destinationPath: string
): Promise<ComparisonResult> {
    
    // Get Merkle trees from both databases
    const sourceAssetDatabase = sourceDatabase.getAssetDatabase();
    const sourceMerkleTree = sourceAssetDatabase.getMerkleTree();
    
    const destAssetDatabase = destinationDatabase.getAssetDatabase();
    const destMerkleTree = destAssetDatabase.getMerkleTree();
    
    console.log(pc.gray(`Source tree: ${sourceMerkleTree.metadata.totalFiles} files`));
    console.log(pc.gray(`Destination tree: ${destMerkleTree.metadata.totalFiles} files`));

    // Fast path: Compare root hashes first
    if (Buffer.compare(sourceMerkleTree.nodes[0].hash, destMerkleTree.nodes[0].hash) === 0) {
        return {
            treesMatch: true,
            message: "Trees are identical (root hashes match)",
            differences: {
                filesOnlyInA: [],
                filesOnlyInB: [],
                modifiedFiles: [],
                deletedFiles: []
            },
            metrics: {
                filesInTreeA: sourceMerkleTree.metadata.totalFiles,
                filesInTreeB: destMerkleTree.metadata.totalFiles,
                totalDifferences: 0
            }
        };
    }

    // Detailed comparison using existing compareTrees function
    const treeComparison = compareTrees(sourceMerkleTree, destMerkleTree);
    
    const totalDifferences = 
        treeComparison.onlyInA.length + 
        treeComparison.onlyInB.length + 
        treeComparison.modified.length + 
        treeComparison.deleted.length;

    return {
        treesMatch: totalDifferences === 0,
        message: totalDifferences === 0 ? "Trees are identical" : `Found ${totalDifferences} differences`,
        differences: {
            filesOnlyInA: treeComparison.onlyInA,
            filesOnlyInB: treeComparison.onlyInB,
            modifiedFiles: treeComparison.modified,
            deletedFiles: treeComparison.deleted
        },
        metrics: {
            filesInTreeA: sourceMerkleTree.metadata.totalFiles,
            filesInTreeB: destMerkleTree.metadata.totalFiles,
            totalDifferences
        }
    };
}

function displayComparisonResults(result: ComparisonResult): void {
    console.log();
    console.log(pc.bold(pc.blue(`📊 Comparison Results`)));
    console.log();
    
    if (result.treesMatch) {
        console.log(pc.green(`No differences detected`));
        return;
    }

    const { differences } = result;
    
    // Summary line
    const summaryParts = [];
    if (differences.filesOnlyInA.length > 0) {
        summaryParts.push(`${differences.filesOnlyInA.length} files only in source`);
    }
    if (differences.filesOnlyInB.length > 0) {
        summaryParts.push(`${differences.filesOnlyInB.length} files only in destination`);
    }
    if (differences.modifiedFiles.length > 0) {
        summaryParts.push(`${differences.modifiedFiles.length} modified files`);
    }
    if (differences.deletedFiles.length > 0) {
        summaryParts.push(`${differences.deletedFiles.length} deleted files`);
    }
    
    console.log(pc.yellow(`Found differences: ${summaryParts.join(', ')}`));
    console.log();

    // Files only in source
    if (differences.filesOnlyInA.length > 0) {
        console.log(pc.cyan(`Files only in source:`));
        const filesToShow = differences.filesOnlyInA.slice(0, 10);
        filesToShow.forEach(file => {
            console.log(`  ${pc.cyan('+')} ${file}`);
        });
        if (differences.filesOnlyInA.length > 10) {
            console.log(pc.gray(`  ... and ${differences.filesOnlyInA.length - 10} more`));
        }
        console.log();
    }

    // Files only in destination
    if (differences.filesOnlyInB.length > 0) {
        console.log(pc.magenta(`Files only in destination:`));
        const filesToShow = differences.filesOnlyInB.slice(0, 10);
        filesToShow.forEach(file => {
            console.log(`  ${pc.magenta('+')} ${file}`);
        });
        if (differences.filesOnlyInB.length > 10) {
            console.log(pc.gray(`  ... and ${differences.filesOnlyInB.length - 10} more`));
        }
        console.log();
    }

    // Modified files
    if (differences.modifiedFiles.length > 0) {
        console.log(pc.yellow(`Modified files:`));
        const filesToShow = differences.modifiedFiles.slice(0, 10);
        filesToShow.forEach(file => {
            console.log(`  ${pc.yellow('●')} ${file}`);
        });
        if (differences.modifiedFiles.length > 10) {
            console.log(pc.gray(`  ... and ${differences.modifiedFiles.length - 10} more`));
        }
        console.log();
    }

    // Deleted files
    if (differences.deletedFiles.length > 0) {
        console.log(pc.red(`Deleted files:`));
        const filesToShow = differences.deletedFiles.slice(0, 10);
        filesToShow.forEach(file => {
            console.log(`  ${pc.red('-')} ${file}`);
        });
        if (differences.deletedFiles.length > 10) {
            console.log(pc.gray(`  ... and ${differences.deletedFiles.length - 10} more`));
        }
        console.log();
    }

    // Metrics
    console.log(pc.gray(`Source files: ${result.metrics.filesInTreeA}`));
    console.log(pc.gray(`Destination files: ${result.metrics.filesInTreeB}`));
    console.log(pc.gray(`Total differences: ${result.metrics.totalDifferences}`));
}

async function writeJsonResults(result: ComparisonResult, outputPath: string): Promise<void> {
    try {
        const jsonOutput = {
            timestamp: new Date().toISOString(),
            ...result
        };
        
        await fs.promises.writeFile(outputPath, JSON.stringify(jsonOutput, null, 2));
        console.log(pc.gray(`Comparison result written to: ${outputPath}`));
    } catch (error) {
        log.error(pc.red(`Failed to write results to ${outputPath}: ${error}`));
    }
}