import { log } from "utils";
import pc from "picocolors";
import { exit } from "node-utils";
import { clearProgressMessage, writeProgress } from '../lib/terminal-utils';
import { loadDatabase, IBaseCommandOptions, ICommandContext } from "../lib/init-cmd";
import * as os from 'os';
import * as path from 'path';
import { checkPaths, HashCache } from "api";
import { FileStorage } from "storage";

export interface ICheckCommandOptions extends IBaseCommandOptions {
}

//
// Command that checks which files and directories have been added to the Photosphere media file database.
//
export async function checkCommand(context: ICommandContext, paths: string[], options: ICheckCommandOptions): Promise<void> {
    const { uuidGenerator, timestampProvider, sessionId } = context;
    const { metadataCollection, localFileScanner } = await loadDatabase(options.db, options, true, uuidGenerator, timestampProvider, sessionId);
    
    // Create hash cache for file hashing optimization
    const localHashCachePath = path.join(os.tmpdir(), `photosphere`);
    const localHashCache = new HashCache(new FileStorage(localHashCachePath), localHashCachePath);
    await localHashCache.load();

    writeProgress(`Searching for files...`);

    let currentSummary = {
        filesAdded: 0,
        filesAlreadyAdded: 0,
        filesIgnored: 0,
        filesFailed: 0,
        totalSize: 0,
        averageSize: 0,
    };

    const addSummary = await checkPaths(
        uuidGenerator,
        metadataCollection,
        localHashCache,
        localFileScanner,
        paths,
        (currentlyScanning) => {
        let progressMessage = `Already in DB: ${pc.green(currentSummary.filesAlreadyAdded)}`;
        if (currentSummary.filesAdded > 0) {
            progressMessage += ` | Would add: ${pc.yellow(currentSummary.filesAdded)}`;
        }
        if (currentSummary.filesIgnored > 0) {
            progressMessage += ` | Ignored: ${pc.gray(currentSummary.filesIgnored)}`;
        }
        if (currentlyScanning) {
            progressMessage += ` | Scanning ${pc.cyan(currentlyScanning)}`;
        }

        progressMessage += ` | ${pc.gray("Abort with Ctrl-C")}`;
        writeProgress(progressMessage);
    }, currentSummary);

    clearProgressMessage(); // Flush the progress message.

    const totalChecked = addSummary.filesAdded + addSummary.filesAlreadyAdded + addSummary.filesIgnored;
    log.info(pc.green(`Checked ${totalChecked} files.\n`));
    
    log.info(pc.bold('Summary:'));
    log.info(`Files added:      ${addSummary.filesAdded}`);
    log.info(`Files ignored:    ${addSummary.filesIgnored}`);
    log.info(`Files failed:     ${addSummary.filesFailed}`);
    log.info(`Already added:    ${addSummary.filesAlreadyAdded}`);

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