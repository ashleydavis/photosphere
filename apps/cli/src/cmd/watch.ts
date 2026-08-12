import pc from "picocolors";
import { log } from "utils";
import { exit, getDefaultPhotoFolders, registerTerminationCallback } from "node-utils";
import { TaskQueue, TaskStatus } from "task-queue";
import type { ITaskMessageData } from "task-queue";
import { loadDatabaseConfig } from "api";
import type { IAutoImportSettings, IDatabaseDescriptor, IFolderAutoImportSource } from "api";
import { DEFAULT_AUTO_IMPORT_SETTINGS } from "api";
import type { IAutoImportData, IAutoImportProgressMessage, IAutoImportResult, IEvictOriginalsResult } from "node-api";
import { loadDatabase, IBaseCommandOptions, ICommandContext, resolveGeocodingApiKey } from "../lib/init-cmd";
import { clearProgressMessage, writeProgress } from "../lib/terminal-utils";
import { formatBytes } from "../lib/format";

//
// Options for the watch command.
//
export interface IWatchCommandOptions extends IBaseCommandOptions {
    //
    // Do a single pass over the sources and exit, rather than watching.
    //
    once?: boolean;

    //
    // Do not sync to the origin after importing.
    //
    noSync?: boolean;

    //
    // Delete each source file once the asset is confirmed in the local database.
    //
    cleanup?: boolean;

    //
    // Drop local originals the origin already holds, after each successful sync.
    //
    evict?: boolean;

    //
    // Keep local originals under this many bytes, instead of the built-in retention policy.
    //
    evictBudget?: string;
}

//
// How long to wait between checks that a background watch is still going, in milliseconds. Short
// enough that Ctrl-C feels immediate.
//
const WATCH_POLL_INTERVAL_MS = 250;

//
// Watches folders for new media and imports it, optionally syncing to the origin and dropping
// local originals the origin already holds.
//
export async function watchCommand(context: ICommandContext, folders: string[], options: IWatchCommandOptions): Promise<void> {
    const { sessionId, uuidGenerator, timestampProvider } = context;

    const { databaseDir, rawAssetStorage, geocodingKeyName } = await loadDatabase(options.db, options, uuidGenerator, timestampProvider, sessionId);
    const googleApiKey = await resolveGeocodingApiKey(geocodingKeyName);

    const watchedFolders = folders.length > 0 ? folders : getDefaultPhotoFolders();
    if (watchedFolders.length === 0) {
        log.error(pc.red("✗ No folders to watch."));
        log.error(pc.red("  This machine has none of the usual photo folders, so name the folders to watch."));
        log.error("");
        log.error(`Example:`);
        log.error(`    ${pc.cyan("psi watch ~/Pictures ~/Camera")}`);
        await exit(1);
        return;
    }

    const sources: IFolderAutoImportSource[] = watchedFolders.map(folderPath => ({
        type: "folder",
        path: folderPath,
        recurse: true,
    }));

    const settings: IAutoImportSettings = {
        ...DEFAULT_AUTO_IMPORT_SETTINGS,
        enabled: true,
        sources,
        cleanupEnabled: options.cleanup || false,
    };

    const storageDescriptor: IDatabaseDescriptor = {
        databasePath: databaseDir,
        encryptionKey: options.key,
    };

    let evictBudgetBytes: number | undefined = undefined;
    if (options.evictBudget !== undefined) {
        evictBudgetBytes = Number(options.evictBudget);
        if (!Number.isFinite(evictBudgetBytes) || evictBudgetBytes < 0) {
            log.error(pc.red(`✗ --evict-budget must be a number of bytes, got "${options.evictBudget}".`));
            await exit(1);
            return;
        }
    }

    const config = await loadDatabaseConfig(rawAssetStorage);
    const origin = config?.origin;
    const syncWanted = !options.noSync && origin !== undefined;

    log.info(pc.bold("Watching for new media."));
    for (const folderPath of watchedFolders) {
        log.info(`  Folder:    ${pc.cyan(folderPath)}`);
    }
    log.info(`  Database:  ${pc.cyan(databaseDir)}`);
    if (origin) {
        log.info(`  Origin:    ${pc.cyan(origin)}${syncWanted ? "" : pc.yellow(" (sync disabled)")}`);
    }
    if (options.cleanup) {
        log.info(pc.yellow("  Source files are deleted once each asset is confirmed in the local database."));
    }
    log.info("");

    const queue = new TaskQueue(uuidGenerator, `watch-${sessionId}`);

    // Set while a sync or an eviction is running, so a burst of import batches does not start a
    // second one on top of the first.
    let followUpRunning = false;

    // How many imports have been reported, so the follow-up only runs when something changed.
    let importedAtLastFollowUp = 0;
    let latestProgress: IAutoImportProgressMessage | undefined = undefined;

    // How many syncs or evictions failed. A watch that imported everything but could not get any of
    // it to the origin has not done what it was asked, and a scheduled backup only reads the exit
    // code, so this is what stops it reporting success.
    let followUpFailures = 0;

    //
    // Syncs to the origin and then drops local originals the origin holds. Only runs when the import
    // actually added something, because syncing an unchanged database is work for nothing.
    //
    async function runFollowUp(): Promise<void> {
        if (followUpRunning || latestProgress === undefined) {
            return;
        }
        if (latestProgress.imported <= importedAtLastFollowUp) {
            return;
        }

        followUpRunning = true;
        importedAtLastFollowUp = latestProgress.imported;

        try {
            if (syncWanted) {
                clearProgressMessage();
                log.info(pc.dim(`Syncing to ${origin}...`));
                const syncTaskId = queue.addTask("sync-database", { databasePath: databaseDir });
                const syncResult = await queue.awaitTask(syncTaskId);

                if (syncResult !== undefined && syncResult.status !== TaskStatus.Succeeded) {
                    followUpFailures += 1;
                    log.error(pc.red(`✗ Sync to ${origin} failed: ${syncResult.errorMessage}`));
                    // Nothing is evicted after a failed sync. Eviction only ever drops what the
                    // origin holds, and a sync that did not run is no evidence of what it holds.
                    return;
                }

                if (options.evict) {
                    const evictTaskId = queue.addTask("evict-originals", {
                        databasePath: databaseDir,
                        sessionId,
                        localOriginalBudgetBytes: evictBudgetBytes,
                    });
                    const evictTaskResult = await queue.awaitTask(evictTaskId);

                    if (evictTaskResult !== undefined && evictTaskResult.status !== TaskStatus.Succeeded) {
                        followUpFailures += 1;
                        log.error(pc.red(`✗ Dropping local originals failed: ${evictTaskResult.errorMessage}`));
                        return;
                    }

                    const evicted = evictTaskResult?.outputs as IEvictOriginalsResult | undefined;
                    if (evicted && evicted.skippedReason) {
                        log.info(pc.yellow(`Nothing was dropped: ${evicted.skippedReason}.`));
                    }
                    else if (evicted && evicted.evictedAssetIds.length > 0) {
                        log.info(pc.dim(`Dropped ${evicted.evictedAssetIds.length} local original(s), freeing ${formatBytes(evicted.freedBytes)}.`));
                    }
                }
            }
        }
        finally {
            followUpRunning = false;
        }
    }

    queue.onTaskMessage<IAutoImportProgressMessage>("auto-import-progress", (data: ITaskMessageData<IAutoImportProgressMessage>) => {
        latestProgress = data.message;

        let progressMessage = `Imported: ${pc.green(String(data.message.imported).padStart(4))}`;
        progressMessage += ` | Existing: ${pc.blue(String(data.message.skipped).padStart(4))}`;
        if (data.message.failed > 0) {
            progressMessage += ` | Failed: ${pc.red(String(data.message.failed).padStart(4))}`;
        }
        if (data.message.deletedFromSource > 0) {
            progressMessage += ` | Deleted from source: ${pc.yellow(String(data.message.deletedFromSource).padStart(4))}`;
        }
        if (!data.message.backfillComplete) {
            progressMessage += ` | Backfill remaining: ${data.message.backfillRemaining}`;
        }
        if (data.message.currentItem) {
            progressMessage += ` | ${pc.cyan(data.message.currentItem)}`;
        }
        writeProgress(progressMessage);
    });

    const autoImportData: IAutoImportData = {
        storageDescriptor,
        settings,
        sessionId,
        once: options.once || false,
        googleApiKey,
    };

    const autoImportTaskId = queue.addTask("auto-import", autoImportData);

    if (!options.once) {
        // Said through the log rather than the progress line, because the progress line only goes to
        // a terminal and this is how anything driving the command knows it is up.
        log.info("Watching. Press Ctrl-C to stop.");
    }

    // Ctrl-C has to reach the task, not just this process: the task is what holds the watchers and
    // the temporary directory, and shutting the queue down is what tells it to stop.
    registerTerminationCallback(async () => {
        queue.shutdown();
    });

    let finished = false;
    const autoImportPromise = queue.awaitTask(autoImportTaskId).then(result => {
        finished = true;
        return result;
    });

    // The follow-up cannot go inside the message handler: it awaits tasks on the same queue, and a
    // message handler that blocks would hold up the messages the awaited task sends.
    while (!finished) {
        await runFollowUp();
        await new Promise<void>(resolve => setTimeout(resolve, WATCH_POLL_INTERVAL_MS));
    }

    const taskResult = await autoImportPromise;
    await runFollowUp();

    clearProgressMessage();
    queue.shutdown();

    const result = taskResult?.outputs as IAutoImportResult | undefined;
    if (!result) {
        log.error(pc.red("✗ The automatic import task ended without reporting a result."));
        await exit(1);
        return;
    }

    log.info("");
    log.info(pc.bold("Summary:"));
    log.info(`Files considered: ${result.seen}`);
    log.info(`Files added:      ${result.imported}`);
    log.info(`Already added:    ${result.skipped}`);
    log.info(`Files failed:     ${result.failed}`);
    if (options.cleanup) {
        log.info(`Source files deleted: ${result.deletedFromSource}`);
    }

    if (followUpFailures > 0) {
        log.info(pc.red(`Sync or eviction failures: ${followUpFailures}`));
    }

    // A file that failed to import is not in the database, and an import that never reached the
    // origin is not backed up, so in either case the command did not do what it was asked. A
    // scheduled backup only reads the exit code, and reporting success here is how an incomplete
    // backup goes unnoticed.
    if (result.failed > 0 || followUpFailures > 0) {
        await exit(1);
    }
    else {
        await exit(0);
    }
}
