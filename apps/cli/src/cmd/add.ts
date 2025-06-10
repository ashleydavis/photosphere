import { MediaFileDatabase } from "api";
import { createStorage, loadEncryptionKeys, pathJoin } from "storage";
import { log } from "utils";
import { configureLog } from "../lib/log";
import pc from "picocolors";
import { exit, registerTerminationCallback } from "node-utils";
import { configureS3IfNeeded } from '../lib/s3-config';
import { getDirectoryForCommand } from '../lib/directory-picker';
import { ensureMediaProcessingTools } from '../lib/ensure-tools';
import { clearProgressMessage, writeProgress } from '../lib/terminal-utils';

export interface IAddCommandOptions { 
    //
    // Set the path to the database metadata.
    //
    meta?: string;

    //
    // Sets the path to private key file for encryption.
    //
    key?: string;

    //
    // Enables verbose logging.
    //
    verbose?: boolean;

    //
    // Non-interactive mode - use defaults and command line arguments.
    //
    yes?: boolean;
}

//
// Command that adds files and directories to the Photosphere media file database.
//
export async function addCommand(dbDir: string, paths: string[], options: IAddCommandOptions): Promise<void> {

    configureLog({
        verbose: options.verbose,
    });

    // Ensure media processing tools are available
    await ensureMediaProcessingTools(options.yes || false);

    // Get the directory for the database (validates it exists and is a media database)
    const databaseDir = await getDirectoryForCommand('existing', dbDir, options.yes || false);
    
    const metaPath = options.meta || pathJoin(databaseDir, '.db');

    //
    // Configure S3 if the path requires it
    //
    if (!await configureS3IfNeeded(databaseDir)) {
        await exit(1);
    }
    
    if (!await configureS3IfNeeded(metaPath)) {
        await exit(1);
    }

    const { options: storageOptions } = await loadEncryptionKeys(options.key, false, "source");

    const { storage: assetStorage } = createStorage(databaseDir, storageOptions);        
    const { storage: metadataStorage } = createStorage(metaPath);

    const database = new MediaFileDatabase(assetStorage, metadataStorage, process.env.GOOGLE_API_KEY); 

    registerTerminationCallback(async () => {
        await database.close();
    });    

    await database.load();

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