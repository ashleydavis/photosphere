import { log } from "utils";
import pc from "picocolors";
import { exit } from "node-utils";
import { clearProgressMessage, writeProgress } from '../lib/terminal-utils';
import { loadDatabase, IBaseCommandOptions } from "../lib/init-cmd";
import { formatBytes } from "../lib/format";
import { verify } from "api";

export interface IVerifyCommandOptions extends IBaseCommandOptions {
    //
    // Force full verification (bypass cached hash optimization).
    //
    full?: boolean;

    //
    // Path to a specific file or directory to verify (instead of entire database).
    //
    path?: string;
}

//
// Command that verifies the integrity of the Photosphere media file database.
//
export async function verifyCommand(options: IVerifyCommandOptions): Promise<void> {
    
    const { database } = await loadDatabase(options.db, options, true);

    writeProgress(options.path 
        ? `🔍 Verifying files matching: ${options.path}` 
        : `🔍 Verifying database integrity`);

    const result = await verify(database, { 
        full: options.full,
        pathFilter: options.path
    }, (progress) => {
        writeProgress(`🔍 ${progress}`);
    });

    clearProgressMessage(); // Flush the progress message.

    log.info('');
    log.info(pc.bold(pc.blue(options.path 
        ? `📊 Verified files matching: ${options.path}` 
        : `📊 Verified ${result.totalFiles} files.`)));
    log.info('');
    
    log.info(`Files imported:   ${pc.cyan(result.totalImports.toString())}`);
    log.info(`Total files:      ${pc.cyan(result.totalFiles.toString())}`);
    log.info(`Total size:       ${pc.cyan(formatBytes(result.totalSize))}`);
    log.info(`Files processed:  ${pc.cyan(result.filesProcessed.toString())}`);
    log.info(`Nodes processed:  ${pc.cyan(result.nodesProcessed.toString())}`);
    log.info(`Unmodified:       ${pc.green(result.numUnmodified.toString())}`);
    log.info(`Modified:         ${result.modified.length > 0 ? pc.red(result.modified.length.toString()) : pc.green('0')}`);
    log.info(`New:              ${result.new.length > 0 ? pc.yellow(result.new.length.toString()) : pc.green('0')}`);
    log.info(`Removed:          ${result.removed.length > 0 ? pc.red(result.removed.length.toString()) : pc.green('0')}`);
        
    // Show details for problematic files
    if (result.modified.length > 0) {
        log.info('');
        log.info(pc.red(`Modified files:`));
        result.modified.forEach(file => {
            log.info(`  ${pc.red('●')} ${file}`);
        });
    }
    
    if (result.new.length > 0) {
        log.info('');
        log.info(pc.yellow(`New files:`));
        result.new.forEach(file => {
            log.info(`  ${pc.yellow('+')} ${file}`);
        });
    }
    
    if (result.removed.length > 0) {
        log.info('');
        log.info(pc.red(`Removed files:`));
        result.removed.forEach(file => {
            log.info(`  ${pc.red('-')} ${file}`);
        });
    }
    
    log.info('');
    if (result.modified.length === 0 && result.new.length === 0 && result.removed.length === 0) {
        log.info(pc.green(`✅ Database verification passed - all files are intact`));
    } else {
        log.info(pc.yellow(`⚠️ Database verification found issues - see details above`));
    }

    // Show follow-up commands
    log.info('');
    log.info(pc.bold('Next steps:'));
    if (result.modified.length > 0 || result.new.length > 0 || result.removed.length > 0) {
        log.info(`    ${pc.cyan('psi repair --source <path>')}   Fix database issues by restoring from source`);
    }
    log.info(`    ${pc.cyan('psi replicate --dest <path>')}   Create a backup copy of your database`);
    log.info(`    ${pc.cyan('psi compare --dest <path>')}     Compare this database with another location`);
    log.info(`    ${pc.cyan('psi summary')}                   View database summary and tree hash`);
    log.info(`    ${pc.cyan('psi ui')}                        Open the web interface to browse your media`);

    await exit(0);
}
