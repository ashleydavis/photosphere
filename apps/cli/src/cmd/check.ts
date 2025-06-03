import { MediaFileDatabase } from "api";
import { createStorage, loadEncryptionKeys, pathJoin } from "storage";
import { log } from "utils";
import { configureLog } from "../lib/log";
import pc from "picocolors";
import { exit, registerTerminationCallback } from "node-utils";
import { configureS3IfNeeded } from '../lib/s3-config';

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
}

//
// Command that checks which files and directories have been added to the Photosphere media file database.
//
export async function checkCommand(dbDir: string, paths: string[], options: ICheckCommandOptions): Promise<void> {

    configureLog({
        verbose: options.verbose,
    });

    //
    // Configure S3 if the path requires it
    //
    if (!await configureS3IfNeeded(dbDir)) {
        process.exit(1);
    }
    
    const metaPath = options.meta || pathJoin(dbDir, '.db');
    if (!await configureS3IfNeeded(metaPath)) {
        process.exit(1);
    }

    const { options: storageOptions } = await loadEncryptionKeys(options.key, false, "source");

    const { storage: assetStorage } = createStorage(dbDir, storageOptions);
    const { storage: metadataStorage } = createStorage(metaPath);

    process.stdout.write(`Searching for files`);

    const database = new MediaFileDatabase(assetStorage, metadataStorage, process.env.GOOGLE_API_KEY); 

    registerTerminationCallback(async () => {
        await database.close();
    });    

    await database.load();

    await database.checkPaths(paths, (currentlyScanning) => {
        process.stdout.clearLine(0);
        process.stdout.cursorTo(0);
        const addSummary = database.getAddSummary();
        process.stdout.write(`Added: ${pc.green(addSummary.numFilesAlreadyAdded)}`);
        if (addSummary.numFilesAdded > 0) {
            process.stdout.write(` | Not added: ${pc.yellow(addSummary.numFilesAdded)}`);
        }
        if (addSummary.numFilesIgnored > 0) {
            process.stdout.write(` | Ignored: ${pc.yellow(addSummary.numFilesIgnored)}`);
        }
        if (addSummary.numFilesFailed > 0) {
            process.stdout.write(` | Failed: ${pc.red(addSummary.numFilesFailed)}`);
        }
        if (currentlyScanning) {
            process.stdout.write(` | Scanning ${pc.cyan(currentlyScanning)}`);
        }

        process.stdout.write(` | ${pc.gray("Abort with Ctrl-C. It is safe to abort and resume later.")}`);
    });

    const addSummary = database.getAddSummary();

    process.stdout.clearLine(0);
    process.stdout.cursorTo(0); // Flush the progress message.

    log.info(pc.green(`Have ${addSummary.numFilesAlreadyAdded} files already added to the media database.\n`));
    
    log.info(`Summary: `);
    log.info(`  - ${addSummary.numFilesAlreadyAdded} files already in the database.`);
    log.info(`  - ${addSummary.numFilesAdded} files to be added.`);
    log.info(`  - ${addSummary.numFilesIgnored} files ignored.`);

    exit(0);
}
