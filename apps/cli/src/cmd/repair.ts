import { log } from "utils";
import pc from "picocolors";
import { exit } from "node-utils";
import { clearProgressMessage, writeProgress } from '../lib/terminal-utils';
import { loadDatabase, IBaseCommandOptions, ICommandContext } from "../lib/init-cmd";
import { formatBytes } from "../lib/format";
import { repair } from "api";

export interface IRepairCommandOptions extends IBaseCommandOptions {
    //
    // The source database to repair from.
    //
    source: string;
    
    //
    // The source key file.
    //
    sourceKey?: string;
    
    //
    // Force full verification (bypass cached hash optimization).
    //
    full?: boolean;
}

//
// Command that repairs the integrity of the Photosphere media file database by restoring files from a source database.
//
export async function repairCommand(context: ICommandContext, options: IRepairCommandOptions): Promise<void> {
    const { uuidGenerator, timestampProvider, sessionId } = context;
    
    if (!options.source) {
        log.error(pc.red("Source database path is required for repair command"));
        await exit(1);
    }
    
    const { assetStorage, metadataStorage, databaseDir: targetDir } = await loadDatabase(options.db, options, uuidGenerator, timestampProvider, sessionId);
    const { assetStorage: sourceAssetStorage, databaseDir: sourceDir } = await loadDatabase(options.source, {
        db: options.source,
        key: options.sourceKey,
        verbose: options.verbose,
        yes: options.yes
    }, uuidGenerator, timestampProvider, sessionId);
    
    log.info('');
    log.info(`Repairing database:`);
    log.info(`  Source:    ${pc.cyan(sourceDir)}`);
    log.info(`  Target:    ${pc.cyan(targetDir)}`);
    log.info('');

    writeProgress(`🔧 Repairing database...`);

    const result = await repair(assetStorage, metadataStorage, sourceAssetStorage, {
        source: options.source,
        sourceKey: options.sourceKey,
        full: options.full,
    }, (progress) => {
        writeProgress(`🔧 ${progress}`);
    });

    clearProgressMessage(); // Flush the progress message.

    log.info('');
    log.info(pc.bold(pc.blue(`🔧 Repair completed - processed ${result.totalFiles} files.`)));
    log.info('');
    
    log.info(`Files imported:   ${pc.cyan(result.totalImports.toString())}`);
    log.info(`Total files:      ${pc.cyan(result.totalFiles.toString())}`);
    log.info(`Total size:       ${pc.cyan(formatBytes(result.totalSize))}`);
    log.info(`Nodes processed:  ${pc.cyan(result.nodesProcessed.toString())}`);
    log.info(`Unmodified:       ${pc.green(result.numUnmodified.toString())}`);
    log.info(`Modified:         ${result.modified.length > 0 ? pc.red(result.modified.length.toString()) : pc.green('0')}`);
    log.info(`New:              ${result.new.length > 0 ? pc.yellow(result.new.length.toString()) : pc.green('0')}`);
    log.info(`Removed:          ${result.removed.length > 0 ? pc.red(result.removed.length.toString()) : pc.green('0')}`);
    log.info(`Repaired:         ${result.repaired.length > 0 ? pc.green(result.repaired.length.toString()) : pc.green('0')}`);
    log.info(`Unrepaired:       ${result.unrepaired.length > 0 ? pc.red(result.unrepaired.length.toString()) : pc.green('0')}`);
        
    // Show details for repaired files
    if (result.repaired.length > 0) {
        log.info('');
        log.info(pc.green(`Repaired files:`));
        result.repaired.slice(0, 10).forEach(file => {
            log.info(`  ${pc.green('✓')} ${file}`);
        });
        if (result.repaired.length > 10) {
            log.info(pc.gray(`  ... and ${result.repaired.length - 10} more`));
        }
    }
    
    // Show details for unrepaired files
    if (result.unrepaired.length > 0) {
        log.info('');
        log.info(pc.red(`Unrepaired files:`));
        result.unrepaired.slice(0, 10).forEach(file => {
            log.info(`  ${pc.red('✗')} ${file}`);
        });
        if (result.unrepaired.length > 10) {
            log.info(pc.gray(`  ... and ${result.unrepaired.length - 10} more`));
        }
    }
    
    // Show details for problematic files
    if (result.modified.length > 0) {
        log.info('');
        log.info(pc.red(`Modified files:`));
        result.modified.slice(0, 10).forEach(file => {
            log.info(`  ${pc.red('●')} ${file}`);
        });
        if (result.modified.length > 10) {
            log.info(pc.gray(`  ... and ${result.modified.length - 10} more`));
        }
    }
    
    if (result.new.length > 0) {
        log.info('');
        log.info(pc.yellow(`New files:`));
        result.new.slice(0, 10).forEach(file => {
            log.info(`  ${pc.yellow('+')} ${file}`);
        });
        if (result.new.length > 10) {
            log.info(pc.gray(`  ... and ${result.new.length - 10} more`));
        }
    }
    
    if (result.removed.length > 0) {
        log.info('');
        log.info(pc.red(`Removed files:`));
        result.removed.slice(0, 10).forEach(file => {
            log.info(`  ${pc.red('-')} ${file}`);
        });
        if (result.removed.length > 10) {
            log.info(pc.gray(`  ... and ${result.removed.length - 10} more`));
        }
    }
    
    log.info('');
    if (result.repaired.length === 0 && result.unrepaired.length === 0 && result.modified.length === 0 && result.new.length === 0 && result.removed.length === 0) {
        log.info(pc.green(`✅ Database repair completed - no issues found`));
    } else if (result.unrepaired.length > 0) {
        log.info(pc.red(`❌ Database repair completed with ${result.unrepaired.length} unrepaired files`));
    } else {
        log.info(pc.green(`✅ Database repair completed successfully`));
    }

    // Show follow-up commands
    log.info('');
    log.info(pc.bold('Next steps:'));
    log.info(`    ${pc.cyan('psi verify')}                     Verify the repaired database integrity`);
    log.info(`    ${pc.cyan('psi summary')}                   View database summary and tree hash`);

    await exit(0);
}