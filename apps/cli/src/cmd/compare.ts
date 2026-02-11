import { log } from "utils";
import pc from "picocolors";
import { exit } from "node-utils";
import { getDirectoryForCommand } from '../lib/directory-picker';
import { compareTrees } from "merkle-tree";
import { clearProgressMessage, writeProgress } from '../lib/terminal-utils';
import { loadDatabase, IBaseCommandOptions, ICommandContext } from "../lib/init-cmd";
import { loadMerkleTree } from "api";

export interface ICompareCommandOptions extends IBaseCommandOptions {
    //
    // Source database directory.
    //
    db?: string;

    //
    // Destination database directory.
    //
    dest?: string;

    //
    // Path to destination encryption key file.
    //
    destKey?: string;

    //
    // Show all differences without truncation.
    //
    full?: boolean;

    //
    // Maximum number of items to show in each category.
    //
    max?: number;
}

//
// Command that compares two asset databases by analyzing their Merkle trees.
//
export async function compareCommand(context: ICommandContext, options: ICompareCommandOptions): Promise<void> {
    const { uuidGenerator, timestampProvider, sessionId } = context;

    const nonInteractive = options.yes || false;

    let srcDir = options.db;
    if (srcDir === undefined) {
        srcDir = await getDirectoryForCommand("existing", nonInteractive, options.cwd || process.cwd());
    }

    let destDir = options.dest;
    if (destDir === undefined) {
        destDir = await getDirectoryForCommand('existing', nonInteractive, options.cwd || process.cwd());
    }

    // Load both databases with allowOlderVersions=false to disallow older databases    
    const { metadataStorage: sourceMetadataStorage, databaseDir: srcDirResolved } = await loadDatabase(srcDir, options, false, uuidGenerator, timestampProvider, sessionId);
    const destOptions = { ...options, db: destDir, key: options.destKey };
    const { metadataStorage: destMetadataStorage, databaseDir: destDirResolved } = await loadDatabase(destDir, destOptions, false, uuidGenerator, timestampProvider, sessionId);

    log.info('');
    log.info(`Comparing two databases:`);
    log.info(`  Source:         ${pc.cyan(srcDirResolved)}`);
    log.info(`  Destination:    ${pc.cyan(destDirResolved)}`);
    log.info('');

    // Load merkle trees from the databases
    const srcMerkleTree = await loadMerkleTree(sourceMetadataStorage);
    if (!srcMerkleTree) {
        clearProgressMessage();
        log.info(pc.red(`Error: Failed to load source database merkle tree`));
        await exit(1);
    }
    
    const destMerkleTree = await loadMerkleTree(destMetadataStorage);
    if (!destMerkleTree) {
        clearProgressMessage();
        log.info(pc.red(`Error: Failed to load destination database merkle tree`));
        await exit(1);
    }

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
        compareResult.modified.length;

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
    
    log.info(pc.yellow(`Found differences: ${summaryParts.join(', ')}`));
    log.info('');

    const showFull = options.full || false;
    const maxItems = options.max || 10;

    // Files only in source
    if (compareResult.onlyInA.length > 0) {
        log.info(pc.cyan(`Files only in source:`));
        const filesToShow = showFull ? compareResult.onlyInA : compareResult.onlyInA.slice(0, maxItems);
        filesToShow.forEach(file => {
            log.info(`  ${pc.cyan('+')} ${file}`);
        });
        if (!showFull && compareResult.onlyInA.length > maxItems) {
            log.info(`  ... and ${compareResult.onlyInA.length - maxItems} more`);
        }
        log.info('');
    }

    // Files only in destination
    if (compareResult.onlyInB.length > 0) {
        log.info(pc.magenta(`Files only in destination:`));
        const filesToShow = showFull ? compareResult.onlyInB : compareResult.onlyInB.slice(0, maxItems);
        filesToShow.forEach(file => {
            log.info(`  ${pc.magenta('+')} ${file}`);
        });
        if (!showFull && compareResult.onlyInB.length > maxItems) {
            log.info(`  ... and ${compareResult.onlyInB.length - maxItems} more`);
        }
        log.info('');
    }

    // Modified files
    if (compareResult.modified.length > 0) {
        log.info(pc.yellow(`Modified files:`));
        const filesToShow = showFull ? compareResult.modified : compareResult.modified.slice(0, maxItems);
        filesToShow.forEach(file => {
            log.info(`  ${pc.yellow('●')} ${file}`);
        });
        if (!showFull && compareResult.modified.length > maxItems) {
            log.info(`  ... and ${compareResult.modified.length - maxItems} more`);
        }
        log.info('');
    }

    log.info(pc.yellow(`⚠️ Databases have ${totalDifferences} differences`));
    await exit(0);
}
