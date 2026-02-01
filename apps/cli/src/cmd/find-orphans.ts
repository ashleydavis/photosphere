import { log } from "utils";
import pc from "picocolors";
import { exit } from "node-utils";
import { loadDatabase, IBaseCommandOptions, ICommandContext } from "../lib/init-cmd";
import { loadMerkleTree } from "api";
import { clearProgressMessage, writeProgress } from '../lib/terminal-utils';
import { findOrphans } from "../lib/find-orphans";
import { getDirectoryForCommand } from '../lib/directory-picker';

export interface IFindOrphansCommandOptions extends IBaseCommandOptions {
    // No additional options needed beyond base options
}

//
// Command that finds and lists files that are no longer in the merkle tree.
//
export async function findOrphansCommand(context: ICommandContext, options: IFindOrphansCommandOptions): Promise<void> {
    const { uuidGenerator, timestampProvider, sessionId } = context;

    const nonInteractive = options.yes || false;

    let dbDir = options.db;
    if (dbDir === undefined) {
        dbDir = await getDirectoryForCommand("existing", nonInteractive, options.cwd || process.cwd());
    }

    // Load the database
    const { assetStorage, metadataStorage, databaseDir } = await loadDatabase(dbDir, options, uuidGenerator, timestampProvider, sessionId);

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
    log.info(pc.bold(pc.blue(`📋 Orphaned Files`)));
    log.info('');

    if (orphans.length === 0) {
        log.info(pc.green(`✓ No orphaned files found`));
    }
    else {
        orphans.forEach(file => {
            log.info(`  ${pc.red('✗')} ${file}`);
        });
        log.info('');
        log.info(pc.yellow(`⚠️  Found ${orphans.length} orphaned file(s) that exist in storage but are not tracked in the merkle tree.`));
        log.info(pc.yellow(`     Use 'psi remove-orphans' to remove them.`));
    }

    await exit(0);
}

