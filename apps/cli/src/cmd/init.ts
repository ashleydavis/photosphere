import { MediaFileDatabase } from "api";
import { createStorage, loadEncryptionKeys, pathJoin } from "storage";
import { configureLog, LogOutputType } from "../lib/log";
import { log } from "utils";
import pc from "picocolors";

export interface IInitCommandOptions { 
    //
    // Set the path to the database metadata.
    //
    meta: string;

    //
    // Sets the path to private key file for encryption.
    //
    key: string;

    //
    // Generates the encryption key if it doesn't exist and saves it to the key file.
    // But only if the key file doesn't exist.
    //
    generateKey: boolean;

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
// Command that initializes a new Photosphere media file database.
//
export async function initCommand(dbDir: string, options: IInitCommandOptions): Promise<void> {

    configureLog({
        output: options.output,
        verbose: options.verbose,
    });

    const { options: storageOptions } = await loadEncryptionKeys(options.key, options.generateKey || false, "source");

    const { storage: assetStorage } = createStorage(dbDir, storageOptions);        
    const { storage: metadataStorage } = createStorage(options.meta || pathJoin(dbDir, '.db'));

    const database = new MediaFileDatabase(assetStorage, metadataStorage, process.env.GOOGLE_API_KEY);
    await database.create(); 

    log.info(pc.green(`Created new media file database in "${dbDir}".`))
}
