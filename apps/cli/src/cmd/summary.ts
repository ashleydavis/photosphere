import pc from "picocolors";
import { exit } from "node-utils";
import { formatBytes } from "../lib/format";
import { loadDatabase, IBaseCommandOptions } from "../lib/init-cmd";
import { log } from "utils";

export interface ISummaryCommandOptions extends IBaseCommandOptions {
}

//
// Command that displays a summary of the Photosphere media file database.
//
export async function summaryCommand(options: ISummaryCommandOptions): Promise<void> {
    
    const { database } = await loadDatabase(options.db, options, true, true);

    const summary = await database.getDatabaseSummary();

    log.info('');
    log.info(pc.bold(pc.blue(`📊 Database Summary`)));
    log.info('');
    log.info(`Files imported:   ${pc.green(summary.totalImports.toString())}`);
    log.info(`Total files:      ${pc.green(summary.totalFiles.toString())}`);
    log.info(`Total size:       ${pc.green(formatBytes(summary.totalSize))}`);
    log.info(`Database version: ${pc.green(summary.databaseVersion.toString())}`);
    if (summary.filesHash) {
        log.info(`Files hash:       ${pc.gray(summary.filesHash)}`);
    }
    if (summary.databaseHash) {
        log.info(`Database hash:    ${pc.gray(summary.databaseHash)}`);
    }
    log.info(`Full root hash:   ${pc.gray(summary.fullHash)}`);

    // Show follow-up commands
    log.info('');
    log.info(pc.bold('Next steps:'));
    log.info(`    ${pc.cyan('psi verify')}                    Verify the integrity of all files in the database`);
    log.info(`    ${pc.cyan('psi add <paths>')}               Add more files to your database`);
    log.info(`    ${pc.cyan('psi replicate --dest <path>')}   Create a backup copy of your database`);
    log.info(`    ${pc.cyan('psi ui')}                        Open the web interface to browse your media`);

    await exit(0);
}

