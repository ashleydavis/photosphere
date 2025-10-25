import { log, RandomUuidGenerator } from "utils";
import { createStorage, pathJoin } from "storage";
import { configureLog } from "../lib/log";
import pc from "picocolors";
import { exit, TestUuidGenerator } from "node-utils";
import { configureIfNeeded, getS3Config } from '../lib/config';
import { getDirectoryForCommand } from '../lib/directory-picker';
import { ensureMediaProcessingTools } from '../lib/ensure-tools';
import { AssetDatabase, compareTrees, loadTree } from "adb";
import { clearProgressMessage, writeProgress } from '../lib/terminal-utils';

export interface ICompareCommandOptions { 
    //
    // Source database directory.
    //
    db?: string;

    //
    // Destination database directory.
    //
    dest?: string;

    //
    // Enables verbose logging.
    //
    verbose?: boolean;

    //
    // Enables tool output logging.
    //
    tools?: boolean;

    //
    // Non-interactive mode - use defaults and command line arguments.
    //
    yes?: boolean;

    //
    // Set the current working directory for directory selection prompts.
    //
    cwd?: string;
}

//
// Command that compares two asset databases by analyzing their Merkle trees.
//
export async function compareCommand(options: ICompareCommandOptions): Promise<void> {

    await configureLog({
        verbose: options.verbose,
        tools: options.tools
    });

    const nonInteractive = options.yes || false;

    // Ensure media processing tools are available
    await ensureMediaProcessingTools(nonInteractive);

    let srcDir = options.db;
    if (srcDir === undefined) {
        srcDir = await getDirectoryForCommand("existing", nonInteractive, options.cwd || process.cwd());
    }

    let destDir = options.dest;
    if (destDir === undefined) {
        destDir = await getDirectoryForCommand('existing', nonInteractive, options.cwd || process.cwd());
    }
    
    const srcMetaPath = pathJoin(srcDir, '.db');
    const destMetaPath = pathJoin(destDir, '.db');

    if (srcDir.startsWith("s3:")) {
        await configureIfNeeded(['s3'], nonInteractive);
    }
    
    if (srcMetaPath.startsWith("s3:")) {
        await configureIfNeeded(['s3'], nonInteractive);
    }

    if (destDir.startsWith("s3:")) {
        await configureIfNeeded(['s3'], nonInteractive);
    }
    
    if (destMetaPath.startsWith("s3:")) {
        await configureIfNeeded(['s3'], nonInteractive);
    }

    const s3Config = await getS3Config();
    const { storage: srcMetadataStorage } = createStorage(srcMetaPath, s3Config);
    const { storage: destMetadataStorage } = createStorage(destMetaPath, s3Config);

    log.info('');
    log.info(`Comparing two databases:`);
    log.info(`  Source:         ${pc.cyan(srcDir)}`);
    log.info(`  Destination:    ${pc.cyan(destDir)}`);
    log.info('');

    // Test providers are automatically configured when NODE_ENV === "testing"
    const uuidGenerator = process.env.NODE_ENV === "testing" 
        ? new TestUuidGenerator()
        : new RandomUuidGenerator();

    const srcAssetDatabase = new AssetDatabase(srcMetadataStorage, srcMetadataStorage, uuidGenerator);
    if (!await srcAssetDatabase.load()) {
        clearProgressMessage();
        log.info(pc.red(`Error: Failed to load source database from ${srcMetaPath}`));
        await exit(1);
    }

    const srcMerkleTree = srcAssetDatabase.getMerkleTree();
    
    const destAssetDatabase = new AssetDatabase(destMetadataStorage, destMetadataStorage, uuidGenerator);
    if (!await destAssetDatabase.load()) {
        clearProgressMessage();
        log.info(pc.red(`Error: Failed to load destination database from ${destMetaPath}`));
        await exit(1);
    }

    const destMerkleTree = destAssetDatabase.getMerkleTree();

    // Fast path: Compare root hashes first
    if (Buffer.compare(srcMerkleTree!.merkle!.hash, destMerkleTree!.merkle!.hash) === 0) {
        log.info('');
        log.info(pc.bold(pc.blue(`📊 Comparison Results`)));
        log.info('');

        log.info(pc.green(`No differences detected`));
        await exit(0);
        return;
    }

    writeProgress(`Comparing trees...`);
    
    const compareResult = compareTrees(srcMerkleTree!, destMerkleTree!, (progress) => {
        writeProgress(`🔍 Comparing | ${progress}`);
    });
    
    clearProgressMessage();

    log.info('');
    log.info(pc.bold(pc.blue(`📊 Comparison Results`)));
    log.info('');
    
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
    
    log.info(pc.yellow(`Found differences: ${summaryParts.join(', ')}`));
    log.info('');

    // Files only in source
    if (compareResult.onlyInA.length > 0) {
        log.info(pc.cyan(`Files only in source:`));
        const filesToShow = compareResult.onlyInA.slice(0, 10);
        filesToShow.forEach(file => {
            log.info(`  ${pc.cyan('+')} ${file}`);
        });
        if (compareResult.onlyInA.length > 10) {
            log.info(pc.gray(`  ... and ${compareResult.onlyInA.length - 10} more`));
        }
        log.info('');
    }

    // Files only in destination
    if (compareResult.onlyInB.length > 0) {
        log.info(pc.magenta(`Files only in destination:`));
        const filesToShow = compareResult.onlyInB.slice(0, 10);
        filesToShow.forEach(file => {
            log.info(`  ${pc.magenta('+')} ${file}`);
        });
        if (compareResult.onlyInB.length > 10) {
            log.info(pc.gray(`  ... and ${compareResult.onlyInB.length - 10} more`));
        }
        log.info('');
    }

    // Modified files
    if (compareResult.modified.length > 0) {
        log.info(pc.yellow(`Modified files:`));
        const filesToShow = compareResult.modified.slice(0, 10);
        filesToShow.forEach(file => {
            log.info(`  ${pc.yellow('●')} ${file}`);
        });
        if (compareResult.modified.length > 10) {
            log.info(pc.gray(`  ... and ${compareResult.modified.length - 10} more`));
        }
        log.info('');
    }

    // Deleted files
    if (compareResult.deleted.length > 0) {
        log.info(pc.red(`Deleted files:`));
        const filesToShow = compareResult.deleted.slice(0, 10);
        filesToShow.forEach(file => {
            log.info(`  ${pc.red('-')} ${file}`);
        });
        if (compareResult.deleted.length > 10) {
            log.info(pc.gray(`  ... and ${compareResult.deleted.length - 10} more`));
        }
        log.info('');
    }

    log.info(pc.yellow(`⚠️ Databases have ${totalDifferences} differences`));
    await exit(0);
}
