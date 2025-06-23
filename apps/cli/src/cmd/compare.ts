import { createStorage, pathJoin } from "storage";
import { configureLog } from "../lib/log";
import pc from "picocolors";
import { exit } from "node-utils";
import { configureS3IfNeeded } from '../lib/s3-config';
import { getDirectoryForCommand } from '../lib/directory-picker';
import { ensureMediaProcessingTools } from '../lib/ensure-tools';
import { compareTrees, loadTreeV2 } from "adb";

export interface ICompareCommandOptions { 
    //
    // Source database directory.
    //
    db: string;

    //
    // Destination database directory.
    //
    dest: string;

    //
    // Source metadata directory override.
    //
    srcMeta?: string;

    //
    // Destination metadata directory override.
    //
    destMeta?: string;

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
// Command that compares two asset databases by analyzing their Merkle trees.
//
export async function compareCommand(options: ICompareCommandOptions): Promise<void> {

    const srcDir = options.db!;
    const destDir = options.dest!;

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

    const { storage: srcMetadataStorage } = createStorage(srcMetaPath);
    const { storage: destMetadataStorage } = createStorage(destMetaPath);

    //
    // Load merkle trees.
    //
    const srcMerkleTree = await loadTreeV2("tree.dat", srcMetadataStorage);
    if (!srcMerkleTree) {
        console.log(pc.red(`Error: Source Merkle tree not found in ${pathJoin(sourceDatabaseDir, 'tree.dat')}`));
        await exit(1);
    }

    const destMerkleTree = await loadTreeV2("tree.dat", destMetadataStorage);
    if (!destMerkleTree) {
        console.log(pc.red(`Error: Destination Merkle tree not found in ${pathJoin(destinationDatabaseDir, 'tree.dat')}`));
        await exit(1);
    }

    console.log(pc.blue(`🔄 Comparing databases`));
    console.log(pc.gray(`Source: ${sourceDatabaseDir}`));
    console.log(pc.gray(`Destination: ${destinationDatabaseDir}`));
   
    console.log(pc.gray(`Source tree: ${srcMerkleTree!.metadata.totalFiles} files`));
    console.log(pc.gray(`Destination tree: ${destMerkleTree!.metadata.totalFiles} files`));

    console.log();
    console.log(pc.bold(pc.blue(`📊 Comparison Results`)));
    console.log();

    // Fast path: Compare root hashes first
    if (Buffer.compare(srcMerkleTree!.nodes[0].hash, destMerkleTree!.nodes[0].hash) === 0) {
        console.log(pc.green(`No differences detected`));
        await exit(0);
        return;
    }

    const compareResult = compareTrees(srcMerkleTree!, destMerkleTree!);
    
    const totalDifferences = 
        compareResult.onlyInA.length + 
        compareResult.onlyInB.length + 
        compareResult.modified.length + 
        compareResult.deleted.length;

    const summaryParts = [];
    if (compareResult.onlyInA.length > 0) {
        summaryParts.push(`${compareResult.onlyInA.length} files only in source`);
    }
    if (compareResult.onlyInB.length > 0) {
        summaryParts.push(`${compareResult.onlyInB.length} files only in destination`);
    }
    if (compareResult.modified.length > 0) {
        summaryParts.push(`${compareResult.modified.length} modified files`);
    }
    if (compareResult.deleted.length > 0) {
        summaryParts.push(`${compareResult.deleted.length} deleted files`);
    }
    
    console.log(pc.yellow(`Found differences: ${summaryParts.join(', ')}`));
    console.log();

    // Files only in source
    if (compareResult.onlyInA.length > 0) {
        console.log(pc.cyan(`Files only in source:`));
        const filesToShow = compareResult.onlyInA.slice(0, 10);
        filesToShow.forEach(file => {
            console.log(`  ${pc.cyan('+')} ${file}`);
        });
        if (compareResult.onlyInA.length > 10) {
            console.log(pc.gray(`  ... and ${compareResult.onlyInA.length - 10} more`));
        }
        console.log();
    }

    // Files only in destination
    if (compareResult.onlyInB.length > 0) {
        console.log(pc.magenta(`Files only in destination:`));
        const filesToShow = compareResult.onlyInB.slice(0, 10);
        filesToShow.forEach(file => {
            console.log(`  ${pc.magenta('+')} ${file}`);
        });
        if (compareResult.onlyInB.length > 10) {
            console.log(pc.gray(`  ... and ${compareResult.onlyInB.length - 10} more`));
        }
        console.log();
    }

    // Modified files
    if (compareResult.modified.length > 0) {
        console.log(pc.yellow(`Modified files:`));
        const filesToShow = compareResult.modified.slice(0, 10);
        filesToShow.forEach(file => {
            console.log(`  ${pc.yellow('●')} ${file}`);
        });
        if (compareResult.modified.length > 10) {
            console.log(pc.gray(`  ... and ${compareResult.modified.length - 10} more`));
        }
        console.log();
    }

    // Deleted files
    if (compareResult.deleted.length > 0) {
        console.log(pc.red(`Deleted files:`));
        const filesToShow = compareResult.deleted.slice(0, 10);
        filesToShow.forEach(file => {
            console.log(`  ${pc.red('-')} ${file}`);
        });
        if (compareResult.deleted.length > 10) {
            console.log(pc.gray(`  ... and ${compareResult.deleted.length - 10} more`));
        }
        console.log();
    }

    console.log(pc.yellow(`⚠️  Databases have ${totalDifferences} differences`));
    await exit(0);
}
