import { log } from "utils";
import pc from "picocolors";
import { exit } from "node-utils";
import { clearProgressMessage, writeProgress } from '../lib/terminal-utils';
import { loadDatabase, IBaseCommandOptions } from "../lib/init-cmd";

export interface IAddCommandOptions extends IBaseCommandOptions {}

//
// Command that adds files and directories to the Photosphere media file database.
//
export async function addCommand(dbDir: string, paths: string[], options: IAddCommandOptions): Promise<void> {
    
    const database = await loadDatabase(dbDir, options);

    writeProgress(`Searching for files...`);

    await database.addPaths(paths, (currentlyScanning) => {
        const addSummary = database.getAddSummary();
        let progressMessage = `Added: ${pc.green(addSummary.numFilesAdded)}`;
        if (addSummary.numFilesAlreadyAdded > 0) {
            progressMessage += ` | Already added: ${pc.blue(addSummary.numFilesAlreadyAdded)}`;
        }
        if (addSummary.numFilesIgnored > 0) {
            progressMessage += ` | Ignored: ${pc.yellow(addSummary.numFilesIgnored)}`;
        }
        if (addSummary.numFilesFailed > 0) {
            progressMessage += ` | Failed: ${pc.red(addSummary.numFilesFailed)}`;
        }
        if (currentlyScanning) {
            progressMessage += ` | Scanning ${pc.cyan(currentlyScanning)}`;
        }

        progressMessage += ` | ${pc.gray("Abort with Ctrl-C. It is safe to abort and resume later.")}`;
        writeProgress(progressMessage);
    });

    const addSummary = database.getAddSummary();

    clearProgressMessage(); // Flush the progress message.

    log.info(pc.green(`Added ${addSummary.numFilesAdded} files to the media database.\n`));
    
    log.info(`Summary: `);
    log.info(`  - ${addSummary.numFilesAdded} files added.`);
    log.info(`  - ${addSummary.numFilesIgnored} files ignored.`);
    log.info(`  - ${addSummary.numFilesFailed} files failed to be added.`);
    log.info(`  - ${addSummary.numFilesAlreadyAdded} files already in the database.`);
    log.info(`  - ${addSummary.totalSize} bytes added to the database.`);
    log.info(`  - ${addSummary.averageSize} bytes average size.`);

    await exit(0);
}