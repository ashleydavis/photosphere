import { log } from "utils";
import pc from "picocolors";
import { exit } from "node-utils";
import { clearProgressMessage, writeProgress } from '../lib/terminal-utils';
import { loadDatabase, IBaseCommandOptions } from "../lib/init-cmd";
import { formatBytes } from "../lib/format";

export interface IVerifyCommandOptions extends IBaseCommandOptions {
    //
    // Force full verification (bypass cached hash optimization).
    //
    full?: boolean;
}

//
// Command that verifies the integrity of the Photosphere media file database.
//
export async function verifyCommand(options: IVerifyCommandOptions): Promise<void> {
    
    const { database, databaseDir } = await loadDatabase(options.db, options);

    log.info('');
    log.info(`Verifying integrity for database in ${pc.cyan(databaseDir)}`);
    log.info('');

    writeProgress(`🔍 Verifying database integrity`);

    const result = await database.verify({ full: options.full }, (progress) => {
        writeProgress(`🔍 ${progress}`);
    });

    clearProgressMessage(); // Flush the progress message.

    console.log();
    log.info(pc.bold(pc.blue(`📊 Verified ${result.totalFiles} files.`)));
    console.log();
    
    console.log(`Files imported: ${pc.cyan(result.filesImported.toString())}`);
    console.log(`Total files: ${pc.cyan(result.totalFiles.toString())}`);
    console.log(`Total size: ${pc.cyan(formatBytes(result.totalSize))}`);
    console.log(`Nodes processed: ${pc.cyan(result.nodesProcessed.toString())}`);
    console.log(`Unmodified: ${pc.green(result.numUnmodified.toString())}`);
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

    // Show follow-up commands
    console.log();
    log.info(pc.bold('Next steps:'));
    if (result.modified.length > 0 || result.new.length > 0 || result.removed.length > 0) {
        console.log(`  ${pc.cyan('psi repair')}                      Fix database issues (command coming soon)`);
    }
    console.log(`  ${pc.cyan('psi replicate --dest <path>')}   Create a backup copy of your database`);
    console.log(`  ${pc.cyan('psi compare --dest <path>')}     Compare this database with another location`);
    console.log(`  ${pc.cyan('psi summary')}                   View database summary and tree hash`);
    console.log(`  ${pc.cyan('psi ui')}                        Open the web interface to browse your media`);

    await exit(0);
}
