import { log } from "utils";
import pc from "picocolors";
import { exit } from "node-utils";
import { clearProgressMessage, writeProgress } from '../lib/terminal-utils';
import { loadDatabase, IBaseCommandOptions, ICommandContext, resolveKeyPath } from "../lib/init-cmd";
import { getS3Config } from "../lib/config";
import { getFileLogger } from "../lib/log";
import * as os from 'os';
import * as path from 'path';
import { checkPaths, HashCache } from "api";
import { FileStorage, IStorageDescriptor } from "storage";

export interface ICheckCommandOptions extends IBaseCommandOptions {
}

//
// Command that checks which files and directories have been added to the Photosphere media file database.
//
export async function checkCommand(context: ICommandContext, paths: string[], options: ICheckCommandOptions): Promise<void> {
    const { uuidGenerator, timestampProvider, sessionId } = context;
    const { databaseDir } = await loadDatabase(options.db, options, true, uuidGenerator, timestampProvider, sessionId);
    
    // Create hash cache for file hashing optimization
    const localHashCachePath = path.join(os.tmpdir(), `photosphere`);
    const localHashCache = new HashCache(localHashCachePath);
    await localHashCache.load();

    // Create storage descriptor for passing to workers
    const resolvedKeyPath = await resolveKeyPath(options.key);
    const storageDescriptor: IStorageDescriptor = {
        dbDir: databaseDir,
        encryptionKeyPath: resolvedKeyPath
    };
    
    // Get S3 config to pass to workers (needed for S3-hosted storage)
    const s3Config = await getS3Config();

    writeProgress(`Searching for files...`);

    const addSummary = await checkPaths(
        storageDescriptor,
        localHashCache,
        paths,
        (currentlyScanning, summary) => {
            let progressMessage = `Already in DB: ${pc.green(summary.filesAlreadyAdded)}`;
            if (summary.filesAdded > 0) {
                progressMessage += ` | Would add: ${pc.yellow(summary.filesAdded)}`;
            }
            if (summary.filesIgnored > 0) {
                progressMessage += ` | Ignored: ${pc.gray(summary.filesIgnored)}`;
            }
            if (currentlyScanning) {
                progressMessage += ` | Scanning ${pc.cyan(currentlyScanning)}`;
            }

            progressMessage += ` | ${pc.gray("Abort with Ctrl-C")}`;
            writeProgress(progressMessage);
        },
        context.taskQueueProvider,
        localHashCachePath,
        s3Config
    );

    clearProgressMessage(); // Flush the progress message.

    const totalChecked = addSummary.filesAdded + addSummary.filesAlreadyAdded + addSummary.filesIgnored;
    log.info(pc.green(`Checked ${totalChecked} files.\n`));
    
    log.info(pc.bold('Summary:'));
    log.info(`Files to add:      ${addSummary.filesAdded}`);
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
        log.info(`    ${pc.cyan('psi add <paths>')}               Add the new files found to your database`);
    }
    log.info(`    ${pc.cyan('psi verify')}                    Verify the integrity of all files in the database`);
    log.info(`    ${pc.cyan('psi summary')}                   View database summary and statistics`);
    log.info(`    ${pc.cyan('psi ui')}                        Open the web interface to browse your media`);

    await exit(0);
}