import { log } from "utils";
import pc from "picocolors";
import { exit } from "node-utils";
import { clearProgressMessage, writeProgress } from '../lib/terminal-utils';
import { loadDatabase, IBaseCommandOptions } from "../lib/init-cmd";

export interface IAddCommandOptions extends IBaseCommandOptions {
}

//
// Command that adds files and directories to the Photosphere media file database.
//
export async function addCommand(paths: string[], options: IAddCommandOptions): Promise<void> {
    
    const database = await loadDatabase(options.db, options);

    writeProgress(`Searching for files...`);

    await database.addPaths(paths, (currentlyScanning) => {
        const addSummary = database.getAddSummary();
        let progressMessage = `Added: ${pc.green(addSummary.filesAdded)}`;
        if (addSummary.filesAlreadyAdded > 0) {
            progressMessage += ` | Already added: ${pc.blue(addSummary.filesAlreadyAdded)}`;
        }
        if (addSummary.filesIgnored > 0) {
            progressMessage += ` | Ignored: ${pc.yellow(addSummary.filesIgnored)}`;
        }
        if (addSummary.filesFailed > 0) {
            progressMessage += ` | Failed: ${pc.red(addSummary.filesFailed)}`;
        }
        if (currentlyScanning) {
            progressMessage += ` | Scanning ${pc.cyan(currentlyScanning)}`;
        }

        progressMessage += ` | ${pc.gray("Abort with Ctrl-C. It is safe to abort and resume later.")}`;
        writeProgress(progressMessage);
    });

    const addSummary = database.getAddSummary();

    clearProgressMessage(); // Flush the progress message.

    log.info(pc.green(`Imported ${addSummary.filesAdded} files to the media database.\n`));
    
    log.info(`Summary: `);
    log.info(`  - Files imported: ${addSummary.filesAdded}`);
    log.info(`  - Files ignored: ${addSummary.filesIgnored}`);
    log.info(`  - Files failed: ${addSummary.filesFailed}`);
    log.info(`  - Assets already in database: ${addSummary.filesAlreadyAdded}`);
    log.info(`  - Total size: ${addSummary.totalSize} bytes`);
    log.info(`  - Average size: ${addSummary.averageSize} bytes`);

    await exit(0);
}