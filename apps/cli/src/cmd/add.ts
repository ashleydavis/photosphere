import { log } from "utils";
import pc from "picocolors";
import { exit } from "node-utils";
import { clearProgressMessage, writeProgress } from '../lib/terminal-utils';
import { loadDatabase, IBaseCommandOptions } from "../lib/init-cmd";
import { configureIfNeeded } from '../lib/config';
import * as fs from 'fs-extra';
import { formatBytes } from "../lib/format";

export interface IAddCommandOptions extends IBaseCommandOptions {
}

//
// Command that adds files and directories to the Photosphere media file database.
//
export async function addCommand(paths: string[], options: IAddCommandOptions): Promise<void> {

    const nonInteractive = options.yes || false;
    
    // Validate that all paths exist before processing
    for (const path of paths) {
        if (!await fs.pathExists(path)) {
            log.error('');
            log.error(pc.red(`✗ Path does not exist: ${pc.cyan(path)}`));
            log.error(pc.red('  Please verify the path is correct and try again.'));
            log.error('');
            await exit(1);
        }
    }
    
    // Configure Google API key for reverse geocoding on first use
    await configureIfNeeded(['google'], nonInteractive);
    
    const { database, databaseDir } = await loadDatabase(options.db, options);

    writeProgress(`Searching for files...`);

    await database.addPaths(paths, (currentlyScanning) => {
        const addSummary = database.getAddSummary();
        let progressMessage = `Added: ${pc.green(addSummary.filesAdded.toString().padStart(4))}`;
        if (addSummary.filesAlreadyAdded > 0) {
            progressMessage += ` | Existing: ${pc.blue(addSummary.filesAlreadyAdded.toString().padStart(4))}`;
        }
        if (addSummary.filesIgnored > 0) {
            progressMessage += ` | Ignored: ${pc.yellow(addSummary.filesIgnored.toString().padStart(4))}`;
        }
        if (addSummary.filesFailed > 0) {
            progressMessage += ` | Failed: ${pc.red(addSummary.filesFailed.toString().padStart(4))}`;
        }
        if (currentlyScanning) {
            progressMessage += ` | Scanning ${pc.cyan(currentlyScanning)}`;
        }

        progressMessage += ` | ${pc.gray("Abort with Ctrl-C. It is safe to abort and resume later.")}`;
        writeProgress(progressMessage);
    });

    const addSummary = database.getAddSummary();

    clearProgressMessage(); // Flush the progress message.

    log.info(pc.green(`Added ${addSummary.filesAdded} files to the media database.\n`));
    
    log.info(pc.bold('Summary:'));
    log.info(`  - Files added:      ${addSummary.filesAdded}`);
    log.info(`  - Files ignored:    ${addSummary.filesIgnored}`);
    log.info(`  - Files failed:     ${addSummary.filesFailed}`);
    log.info(`  - Already added:    ${addSummary.filesAlreadyAdded}`);
    log.info(`  - Total size:       ${formatBytes(addSummary.totalSize)}`);
    log.info(`  - Average size:     ${formatBytes(addSummary.averageSize)}`);

    // Show follow-up commands
    log.info('');
    log.info(pc.bold('Next steps:'));
    log.info(`  ${pc.cyan('psi verify')}                    Verify the integrity of all files in the database`);
    log.info(`  ${pc.cyan('psi summary')}                   View database summary and tree hash`);
    log.info(`  ${pc.cyan('psi replicate --dest <path>')}   Replicate the database to another location`);
    log.info(`  ${pc.cyan('psi ui')}                        Open the web interface to browse your media`);

    await exit(0);
}