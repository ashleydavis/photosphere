import { log } from "utils";
import pc from "picocolors";
import { exit } from "node-utils";
import { clearProgressMessage, writeProgress } from '../lib/terminal-utils';
import { loadDatabase, IBaseCommandOptions, ICommandContext, resolveKeyPath } from "../lib/init-cmd";
import { configureIfNeeded, getGoogleApiKey, getS3Config } from '../lib/config';
import { getFileLogger } from "../lib/log";
import { pathExists } from 'node-utils';
import * as os from 'os';
import * as path from 'path';
import { formatBytes } from "../lib/format";
import { addPaths, HashCache } from "api";
import { IStorageDescriptor } from "storage";

export interface IAddCommandOptions extends IBaseCommandOptions {
    dryRun?: boolean;
}

//
// Command that adds files and directories to the Photosphere media file database.
//
export async function addCommand(context: ICommandContext, paths: string[], options: IAddCommandOptions): Promise<void> {
    const { uuidGenerator, timestampProvider, sessionId, sessionTempDir, taskQueueProvider } = context;

    const nonInteractive = options.yes || false;
    
    // Validate that all paths exist before processing
    for (const path of paths) {
        if (!await pathExists(path)) {
            log.error('');
            log.error(pc.red(`✗ Path does not exist: ${pc.cyan(path)}`));
            log.error(pc.red('  Please verify the path is correct and try again.'));
            log.error('');
            await exit(1);
        }
    }
    
    // Configure Google API key for reverse geocoding on first use
    await configureIfNeeded(['google'], nonInteractive);
    const googleApiKey = await getGoogleApiKey();
    
    const { metadataStorage, metadataCollection, databaseDir } = await loadDatabase(options.db, options, false, uuidGenerator, timestampProvider, sessionId);
    
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

    const addSummary = await addPaths(
        metadataStorage,
        googleApiKey,
        uuidGenerator,
        sessionId,
        metadataCollection,
        localHashCache,
        paths,
        (currentlyScanning, summary) => {
            let progressMessage = options.dryRun 
                ? `Would add: ${pc.green(summary.filesAdded.toString().padStart(4))}`
                : `Added: ${pc.green(summary.filesAdded.toString().padStart(4))}`;
            if (summary.filesAlreadyAdded > 0) {
                progressMessage += ` | Existing: ${pc.blue(summary.filesAlreadyAdded.toString().padStart(4))}`;
            }
            if (summary.filesIgnored > 0) {
                progressMessage += ` | Ignored: ${pc.yellow(summary.filesIgnored.toString().padStart(4))}`;
            }
            if (summary.filesFailed > 0) {
                progressMessage += ` | Failed: ${pc.red(summary.filesFailed.toString().padStart(4))}`;
            }
            if (currentlyScanning) {
                progressMessage += ` | Scanning ${pc.cyan(currentlyScanning)}`;
            }
            if (options.dryRun) {
                progressMessage += ` | ${pc.yellow("DRY RUN")}`;
            }

            progressMessage += ` | ${pc.gray("Abort with Ctrl-C. It is safe to abort and resume later.")}`;
            writeProgress(progressMessage);
        },
        sessionTempDir,
        taskQueueProvider,
        storageDescriptor,
        s3Config,
        options.dryRun || false
    );

    clearProgressMessage(); // Flush the progress message.

    if (options.dryRun) {
        log.info(pc.yellow(`[DRY RUN] Would add ${addSummary.filesAdded} files to the media database.\n`));
    }
    else {
        log.info(pc.green(`Added ${addSummary.filesAdded} files to the media database.\n`));
    }
    
    log.info(pc.bold('Summary:'));
    log.info(`Files considered: ${addSummary.filesProcessed}`);
    log.info(`Files added:      ${addSummary.filesAdded}`);
    log.info(`Files ignored:    ${addSummary.filesIgnored}`);
    log.info(`Files failed:     ${addSummary.filesFailed}`);
    log.info(`Already added:    ${addSummary.filesAlreadyAdded}`);
    log.info(`Total size:       ${formatBytes(addSummary.totalSize)}`);
    log.info(`Average size:     ${formatBytes(addSummary.averageSize)}`);

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
    log.info(pc.gray(`    # Verify the integrity of all files in the database`));
    log.info(`    psi verify`);
    log.info('');
    log.info(pc.gray(`    # View database summary and tree hash`));
    log.info(`    psi summary`);
    log.info('');
    log.info(pc.gray(`    # Replicate the database to another location`));
    log.info(`    psi replicate --db ${databaseDir} --dest <path>`);
    log.info('');
    log.info(pc.gray(`    # Synchronize changes between two databases that have been independently changed`));
    log.info(`    psi sync --db ${databaseDir} --dest <path>`);
    log.info('');
    log.info(pc.gray(`    # Open the web interface to browse your media`));
    log.info(`    psi ui`);

    await exit(0);
}