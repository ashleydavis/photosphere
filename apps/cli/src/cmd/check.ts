import { log } from "utils";
import pc from "picocolors";
import { exit } from "node-utils";
import { clearProgressMessage, writeProgress } from '../lib/terminal-utils';
import { loadDatabase, IBaseCommandOptions } from "../lib/init-cmd";

export interface ICheckCommandOptions extends IBaseCommandOptions {}

//
// Command that checks which files and directories have been added to the Photosphere media file database.
//
export async function checkCommand(dbDir: string, paths: string[], options: ICheckCommandOptions): Promise<void> {
    
    const database = await loadDatabase(dbDir, options);

    writeProgress(`Searching for files...`);

    await database.checkPaths(paths, (currentlyScanning) => {
        const addSummary = database.getAddSummary();
        let progressMessage = `Already in DB: ${pc.green(addSummary.filesAlreadyAdded)}`;
        if (addSummary.filesAdded > 0) {
            progressMessage += ` | Would add: ${pc.yellow(addSummary.filesAdded)}`;
        }
        if (addSummary.filesIgnored > 0) {
            progressMessage += ` | Ignored: ${pc.gray(addSummary.filesIgnored)}`;
        }
        if (currentlyScanning) {
            progressMessage += ` | Scanning ${pc.cyan(currentlyScanning)}`;
        }

        progressMessage += ` | ${pc.gray("Abort with Ctrl-C")}`;
        writeProgress(progressMessage);
    });

    const addSummary = database.getAddSummary();

    clearProgressMessage(); // Flush the progress message.

    const totalChecked = addSummary.filesAdded + addSummary.filesAlreadyAdded + addSummary.filesIgnored;
    log.info(pc.green(`Checked ${totalChecked} files.\n`));
    
    log.info(`Summary: `);
    log.info(`  - ${addSummary.filesAlreadyAdded} files already in database.`);
    log.info(`  - ${addSummary.filesAdded} files would be added to database.`);
    log.info(`  - ${addSummary.filesIgnored} files ignored (not media files).`);

    await exit(0);
}