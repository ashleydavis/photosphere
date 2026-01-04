import { log } from "utils";
import pc from "picocolors";
import { exit } from "node-utils";
import { loadDatabase, IBaseCommandOptions, ICommandContext } from "../lib/init-cmd";
import { loadMerkleTree } from "api";
import { clearProgressMessage, writeProgress } from '../lib/terminal-utils';
import { findOrphans } from "../lib/find-orphans";
import { getDirectoryForCommand } from '../lib/directory-picker';
import { confirm } from '../lib/clack/prompts';
import { isCancel } from '../lib/clack/prompts';

export interface IRemoveOrphansCommandOptions extends IBaseCommandOptions {
    // No additional options needed beyond base options
}

//
// Command that finds and removes files that are no longer in the merkle tree.
//
export async function removeOrphansCommand(context: ICommandContext, options: IRemoveOrphansCommandOptions): Promise<void> {
    const { uuidGenerator, timestampProvider, sessionId } = context;

    const nonInteractive = options.yes || false;

    let dbDir = options.db;
    if (dbDir === undefined) {
        dbDir = await getDirectoryForCommand("existing", nonInteractive, options.cwd || process.cwd());
    }

    // Load the database
    const { assetStorage, metadataStorage, databaseDir } = await loadDatabase(dbDir, options, false, uuidGenerator, timestampProvider, sessionId);

    log.info('');
    log.info(`Finding orphaned files in database:`);
    log.info(`  Database: ${pc.cyan(databaseDir)}`);
    log.info('');

    // Load merkle tree
    writeProgress(`Loading merkle tree...`);
    const merkleTree = await loadMerkleTree(metadataStorage);
    if (!merkleTree) {
        clearProgressMessage();
        log.info(pc.red(`Error: Failed to load merkle tree`));
        await exit(1);
        return; // TypeScript type narrowing
    }

    // Find orphans
    writeProgress(`Scanning for orphaned files...`);
    const orphans = await findOrphans(assetStorage, merkleTree);
    clearProgressMessage();

    log.info('');
    log.info(pc.bold(pc.blue(`🗑️  Remove Orphaned Files`)));
    log.info('');

    if (orphans.length === 0) {
        log.info(pc.green(`✓ No orphaned files found`));
        await exit(0);
        return;
    }

    orphans.forEach(file => {
        log.info(`  ${pc.red('✗')} ${file}`);
    });
    log.info('');

    // Confirm deletion
    if (!nonInteractive) {
        const shouldDelete = await confirm({
            message: `Delete ${orphans.length} orphaned file(s)?`,
            initialValue: false,
        });

        if (isCancel(shouldDelete) || !shouldDelete) {
            log.info(pc.yellow(`Cancelled. No files were deleted.`));
            await exit(0);
            return;
        }
    }

    // Delete orphaned files
    writeProgress(`Deleting orphaned files...`);
    let deletedCount = 0;
    let errorCount = 0;

    for (const file of orphans) {
        try {
            await assetStorage.deleteFile(file);
            deletedCount++;
            if (options.verbose) {
                log.verbose(`Deleted: ${file}`);
            }
        }
        catch (error: unknown) {
            errorCount++;
            const errorMessage = error instanceof Error ? error.message : String(error);
            log.error(`Failed to delete ${file}: ${errorMessage}`);
        }
    }

    clearProgressMessage();

    log.info('');
    if (errorCount === 0) {
        log.info(pc.green(`✓ Successfully deleted ${deletedCount} orphaned file(s)`));
    }
    else {
        log.info(pc.yellow(`⚠️  Deleted ${deletedCount} file(s), ${errorCount} error(s)`));
    }

    await exit(0);
}

