import { MediaFileDatabase } from "api";
import { createStorage, loadEncryptionKeys, pathJoin } from "storage";
import { log } from "utils";
import { configureLog } from "../lib/log";
import pc from "picocolors";
import { exit, registerTerminationCallback } from "node-utils";
import { configureS3IfNeeded } from '../lib/s3-config';
import { getDirectoryForCommand } from '../lib/directory-picker';
import { ensureMediaProcessingTools } from '../lib/ensure-tools';

export interface ICheckCommandOptions { 
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
// Command that checks which files and directories have been added to the Photosphere media file database.
//
export async function checkCommand(dbDir: string, paths: string[], options: ICheckCommandOptions): Promise<void> {

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
        exit(1);
    }
    
    if (!await configureS3IfNeeded(metaPath)) {
        exit(1);
    }

    const { options: storageOptions } = await loadEncryptionKeys(options.key, false, "source");

    const { storage: assetStorage } = createStorage(databaseDir, storageOptions);        
    const { storage: metadataStorage } = createStorage(metaPath);

    const database = new MediaFileDatabase(assetStorage, metadataStorage, process.env.GOOGLE_API_KEY); 

    registerTerminationCallback(async () => {
        await database.close();
    });    

    await database.load();

    process.stdout.write(`Checking files`);

    await database.checkPaths(paths, (currentlyScanning) => {
        process.stdout.clearLine(0);
        process.stdout.cursorTo(0);
        const addSummary = database.getAddSummary();
        process.stdout.write(`Already in DB: ${pc.green(addSummary.numFilesAlreadyAdded)}`);
        if (addSummary.numFilesAdded > 0) {
            process.stdout.write(` | Would add: ${pc.yellow(addSummary.numFilesAdded)}`);
        }
        if (addSummary.numFilesIgnored > 0) {
            process.stdout.write(` | Ignored: ${pc.gray(addSummary.numFilesIgnored)}`);
        }
        if (currentlyScanning) {
            process.stdout.write(` | Scanning ${pc.cyan(currentlyScanning)}`);
        }

        process.stdout.write(` | ${pc.gray("Abort with Ctrl-C")}`);
    });

    const addSummary = database.getAddSummary();

    process.stdout.clearLine(0);
    process.stdout.cursorTo(0); // Flush the progress message.

    const totalFiles = addSummary.numFilesAdded + addSummary.numFilesAlreadyAdded + addSummary.numFilesIgnored;
    log.info(pc.green(`Checked ${totalFiles} files.\n`));
    
    log.info(`Summary: `);
    log.info(`  - ${addSummary.numFilesAlreadyAdded} files already in database.`);
    log.info(`  - ${addSummary.numFilesAdded} files would be added to database.`);
    log.info(`  - ${addSummary.numFilesIgnored} files ignored (not media files).`);

    exit(0);
}