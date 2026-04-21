import { log } from "utils";
import pc from "picocolors";
import { exit } from "node-utils";
import { clearProgressMessage, writeProgress } from '../lib/terminal-utils';
import { loadDatabase, IBaseCommandOptions, ICommandContext, resolveKeyPems } from "../lib/init-cmd";
import { getFileLogger } from "../lib/log";
import { checkPaths } from "api";
import { IStorageDescriptor } from "storage";

export interface ICheckCommandOptions extends IBaseCommandOptions {
}

//
// Command that checks which files and directories have been added to the Photosphere media file database.
//
export async function checkCommand(context: ICommandContext, paths: string[], options: ICheckCommandOptions): Promise<void> {
    const { uuidGenerator, timestampProvider, sessionId, sessionTempDir } = context;
    const { databaseDir, s3Config } = await loadDatabase(options.db, options, uuidGenerator, timestampProvider, sessionId);

    // Create storage descriptor for passing to workers
    const keyPems = await resolveKeyPems(options.key);
    const storageDescriptor: IStorageDescriptor = {
        dbDir: databaseDir,
        encryptionKeyPems: keyPems
    };

    writeProgress(`Searching for files...`);

    const addSummary = await checkPaths(
        storageDescriptor,
        paths,
        (currentlyScanning, summary) => {
            let progressMessage = `Already in DB: ${pc.green(summary.filesAlreadyAdded)}`;
            if (summary.filesAdded > 0) {
                progressMessage += ` | Would add: ${pc.yellow(summary.filesAdded)}`;
            }
            if (summary.filesIgnored > 0) {
                progressMessage += ` | Ignored: ${summary.filesIgnored}`;
            }
            if (currentlyScanning) {
                progressMessage += ` | Scanning ${pc.cyan(currentlyScanning)}`;
            }

            progressMessage += " | Abort with Ctrl-C";
            writeProgress(progressMessage);
        },
        s3Config,
        uuidGenerator,
        sessionTempDir
    );

    clearProgressMessage(); // Flush the progress message.

    const totalChecked = addSummary.filesAdded + addSummary.filesAlreadyAdded + addSummary.filesIgnored;
    log.info(pc.green(`Checked ${totalChecked} files.\n`));
    
    log.info(pc.bold('Summary:'));
    log.info(`Files considered: ${addSummary.filesProcessed}`);
    log.info(`Files to add:     ${addSummary.filesAdded}`);
    log.info(`Files ignored:    ${addSummary.filesIgnored}`);
    log.info(`Files failed:     ${addSummary.filesFailed}`);
    log.info(`Already added:    ${addSummary.filesAlreadyAdded}`);

    // If there were failures, tell the user to check the log file
    if (addSummary.filesFailed > 0) {
        const fileLogger = getFileLogger();
        if (fileLogger) {
            const logFilePath = fileLogger.getLogFilePath();
            log.info('');
            log.info(pc.yellow(`⚠️  ${addSummary.filesFailed} file${addSummary.filesFailed === 1 ? '' : 's'} failed. Check the log file for details:`));
            log.info(`    ${pc.cyan(logFilePath)}`);
        }
    }

    // Show follow-up commands
    log.info('');
    log.info(pc.bold('Next steps:'));
    if (addSummary.filesAdded > 0) {
        log.info(`    # Add the new files found to your database`);
        log.info(`    psi add <paths> --db ${databaseDir}`);
        log.info('');
    }
    log.info(`    # Verify the integrity of all files in the database`);
    log.info(`    psi verify --db ${databaseDir}`);
    log.info('');
    log.info(`    # View database summary and statistics`);
    log.info(`    psi summary --db ${databaseDir}`);

    await exit(0);
}