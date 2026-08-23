import { log, sleep } from "utils";
import pc from "picocolors";
import { exit } from "node-utils";
import { clearProgressMessage, writeProgress } from '../lib/terminal-utils';
import { loadDatabase, IBaseCommandOptions, ICommandContext, resolveGeocodingApiKey } from "../lib/init-cmd";
import { getFileLogger } from "../lib/log";
import { pathExists } from 'node-utils';
import { formatBytes } from "../lib/format";
import type { IDatabaseDescriptor } from "api";
import { addPaths } from "node-api";
import type { IAddSummary } from "node-api";
import { TaskQueue } from "task-queue";
import { getDefaultPhotoFolders } from "node-utils";
import { DEFAULT_AUTO_IMPORT_SETTINGS } from "api";
import type { IAutoImportSettings } from "api";
import type { ICleanupSourcesResult } from "node-api";
import type { IUuidGenerator } from "utils";

//
// How long the CLI waits before running the import again under `--watch`. Shorter than the
// desktop and mobile apps wait, because a person is sitting in front of this one watching it.
//
const WATCH_RESTART_INTERVAL_MS = 5000;

export interface IAddCommandOptions extends IBaseCommandOptions {
    dryRun?: boolean;

    //
    // Keep watching the named folders and import what turns up, rather than walking them once and
    // stopping.
    //
    watch?: boolean;

    //
    // Delete the source files the database is confirmed to hold, once the import has finished.
    //
    cleanup?: boolean;
}

//
// Command that adds files and directories to the Photosphere media file database.
//
export async function addCommand(context: ICommandContext, paths: string[], options: IAddCommandOptions): Promise<void> {
    const { sessionId, uuidGenerator, timestampProvider } = context;

    const nonInteractive = options.yes || false;

    // Validate that all paths exist before processing.
    for (const filePath of paths) {
        if (!await pathExists(filePath)) {
            log.error('');
            log.error(pc.red(`✗ Path does not exist: ${pc.cyan(filePath)}`));
            log.error(pc.red('  Please verify the path is correct and try again.'));
            log.error('');
            await exit(1);
        }
    }
    
    const { databaseDir, geocodingKeyName } = await loadDatabase(options.db, options, uuidGenerator, timestampProvider, sessionId);
    const googleApiKey = await resolveGeocodingApiKey(geocodingKeyName);

    const storageDescriptor: IDatabaseDescriptor = {
        databasePath: databaseDir,
        encryptionKey: options.key,
    };

    // With --watch the same import task is fed by a scanner that watches these folders and imports
    // what turns up, instead of walking them once. That is the only difference between the two:
    // everything below is shared, so `psi add` exercises nearly all of what a watch does.
    const importOptions = options.watch
        ? {
            auto: true,
            ...watchSettings(paths),
        }
        : undefined;
    if (options.watch) {
        log.info(pc.bold("Watching for new media. Press Ctrl-C to stop."));
    }

    writeProgress(`Searching for files...`);

    // An import reads its sources to the end and then stops, so a watch is that same import run
    // again and again, exactly as the desktop and mobile apps restart theirs. Ctrl-C ends the
    // process, which is what ends this loop.
    let addSummary: IAddSummary;
    while (true) {
        addSummary = await runImport();
        if (!options.watch) {
            break;
        }
        await sleep(WATCH_RESTART_INTERVAL_MS);
    }

    //
    // Runs the import once over the paths, reporting progress as it goes.
    //
    async function runImport(): Promise<IAddSummary> {
        return await addPaths(
            uuidGenerator,
            storageDescriptor,
            paths,
            googleApiKey,
            sessionId,
            options.dryRun || false,
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

                progressMessage += ` | Abort with Ctrl-C. It is safe to abort and resume later.`;
                writeProgress(progressMessage);
            },
            importOptions,
        );
    }

    clearProgressMessage(); // Flush the progress message.

    if (options.cleanup) {
        // After the import rather than during it, and as one walk rather than per file. The CLI has
        // no confirmation dialog in front of deleting a file, so unlike mobile it needs no button:
        // only what triggers this differs between the two, and it differs because only a phone puts
        // a system prompt in front of it.
        log.info(pc.dim("Looking for source files the database already holds..."));
        const deleted = await cleanUpImportedSources(uuidGenerator, storageDescriptor, watchSettings(paths), sessionId);
        log.info(`Source files deleted: `);
    }

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
    log.info(`    # Verify the integrity of all files in the database`);
    log.info(`    psi verify`);
    log.info('');
    log.info(`    # View database summary and tree hash`);
    log.info(`    psi summary`);
    log.info('');
    log.info(`    # Replicate the database to another location`);
    log.info(`    psi replicate --db ${databaseDir} --dest <path>`);
    log.info('');
    log.info(`    # Synchronize changes between two databases that have been independently changed`);
    log.info(`    psi sync --db ${databaseDir} --dest <path>`);

    // A file that failed to import did not make it into the database, so the command did not do what
    // it was asked. The counts above say so on screen, but a script or a scheduled backup only reads
    // the exit code, and reporting success there is how an incomplete import goes unnoticed.
    if (addSummary.filesFailed > 0) {
        await exit(1);
    }
    else {
        await exit(0);
    }
}
//
// The places `--watch` watches: the folders named on the command line, or this operating system's
// own photo folders when none were.
//
// The pacing and the poll interval are not offered as options, so they stay at the shared defaults
// rather than being invented here: a watch from the CLI behaves exactly as the app's does.
//
function watchSettings(folders: string[]): IAutoImportSettings {
    const watchedFolders = folders.length > 0 ? folders : getDefaultPhotoFolders();
    return {
        ...DEFAULT_AUTO_IMPORT_SETTINGS,
        enabled: true,
        sources: watchedFolders.map(folderPath => ({ type: "folder", path: folderPath, recurse: true })),
    };
}

//
// Deletes the source files the database is confirmed to hold, and returns how many went.
//
async function cleanUpImportedSources(
    uuidGenerator: IUuidGenerator,
    storageDescriptor: IDatabaseDescriptor,
    settings: IAutoImportSettings,
    sessionId: string
): Promise<number> {
    const queue = new TaskQueue(uuidGenerator, `cleanup-${sessionId}`);
    try {
        const taskId = queue.addTask("cleanup-sources", { storageDescriptor, settings, dryRun: false });
        const taskResult = await queue.awaitTask(taskId);
        const cleanupResult = taskResult?.outputs as ICleanupSourcesResult | undefined;
        if (!cleanupResult) {
            return 0;
        }

        if (cleanupResult.failedSourceIds.length > 0) {
            log.error(pc.red(`✗ ${cleanupResult.failedSourceIds.length} source file(s) could not be deleted.`));
        }
        return cleanupResult.deletedSourceIds.length;
    }
    finally {
        queue.shutdown();
    }
}
