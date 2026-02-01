import pc from "picocolors";
import { exit } from "node-utils";
import { formatBytes } from "../lib/format";
import { loadDatabase, IBaseCommandOptions, ICommandContext } from "../lib/init-cmd";
import { log } from "utils";
import { getDatabaseSummary } from "api";

export interface ISummaryCommandOptions extends IBaseCommandOptions {
}

//
// Command that displays a summary of the Photosphere media file database.
//
export async function summaryCommand(context: ICommandContext, options: ISummaryCommandOptions): Promise<void> {
    const { uuidGenerator, timestampProvider, sessionId } = context;
    const { assetStorage, metadataStorage, databaseDir } = await loadDatabase(options.db, options, uuidGenerator, timestampProvider, sessionId);

    const summary = await getDatabaseSummary(assetStorage, metadataStorage);

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
    log.info(pc.gray(`    # Verify the integrity of all files in the database`));
    log.info(`    psi verify`);
    log.info('');
    log.info(pc.gray(`    # Add more files to your database`));
    log.info(`    psi add <paths>`);
    log.info('');
    log.info(pc.gray(`    # Create a backup copy of your database`));
    log.info(`    psi replicate --db ${databaseDir} --dest <path>`);
    log.info('');
    log.info(pc.gray(`    # Synchronize changes between two databases that have been independently changed`));
    log.info(`    psi sync --db ${databaseDir} --dest <path>`);

    await exit(0);
}

