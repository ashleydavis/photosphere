import { MediaFileDatabase } from "api";
import { createStorage, loadEncryptionKeys, pathJoin } from "storage";
import { log } from "utils";
import { configureLog, LogOutputType } from "../lib/log";
import pc from "picocolors";

export interface IAddCommandOptions { 
    //
    // Set the path to the database metadata.
    //
    meta: string;

    //
    // Sets the path to private key file for encryption.
    //
    key: string;

    //
    // Sets the output type for the command.
    //
    output: LogOutputType;

    //
    // Enables verbose logging.
    //
    verbose: boolean;
}

//
// Command that adds files and directories to the Photosphere media file database.
//
export async function addCommand(dbDir: string, paths: string[], options: IAddCommandOptions): Promise<void> {

    configureLog({
        output: options.output,
        verbose: options.verbose,
    });

    const { options: storageOptions } = await loadEncryptionKeys(options.key, false, "source");

    const { storage: assetStorage } = createStorage(dbDir, storageOptions);
    const { storage: metadataStorage } = createStorage(options.meta || pathJoin(dbDir, '.db'));

    process.stdout.write(`Searching for files`);

    const database = new MediaFileDatabase(assetStorage, metadataStorage, process.env.GOOGLE_API_KEY); 
    await database.load();

    try {
        await database.addPaths(paths, (currentlyScanning) => {
            process.stdout.clearLine(0);
            process.stdout.cursorTo(0);
            const addSummary = database.getAddSummary();
            process.stdout.write(`Added: ${addSummary.numFilesAdded}`);
            if (addSummary.numFilesIgnored) {
                process.stdout.write(` | Ignored: ${addSummary.numFilesIgnored}`);
            }
            if (addSummary.numFilesFailed) {
                process.stdout.write(` | Failed: ${addSummary.numFilesFailed}`);
            }
            if (addSummary.numFilesAlreadyAdded) {  
                process.stdout.write(` | Skipped: ${addSummary.numFilesAlreadyAdded}`);
            }
            if (currentlyScanning) {
                process.stdout.write(` | Scanning ${currentlyScanning}...`);
            }
        });

        const addSummary = database.getAddSummary();

        process.stdout.clearLine(0);
        process.stdout.cursorTo(0); // Flush the progress message.
    
        console.log(pc.green(`Added ${addSummary.numFilesAdded} files to the media database.\n`));
        
        log.info(`Summary: `);
        log.info(`  - ${addSummary.numFilesAdded} files added.`);
        log.info(`  - ${addSummary.numFilesIgnored} files ignored.`);
        log.info(`  - ${addSummary.numFilesFailed} files failed to be added.`);
        log.info(`  - ${addSummary.numFilesAlreadyAdded} files already in the database.`);
        log.info(`  - ${addSummary.totalSize} bytes added to the database.`);
        log.info(`  - ${addSummary.averageSize} bytes average size.`);

        process.exit(0);
    }
    finally {
        await database.close();
    }
}
