import { MediaFileDatabase } from "api";
import { createStorage, loadEncryptionKeys, pathJoin } from "storage";
import { log } from "utils";

//
// Initializes a new Photosphere media file database.
//
export async function initCommand(dbDir: string, options: any): Promise<void> {

    const { options: storageOptions } = await loadEncryptionKeys(options.key, options.generateKey || false, "source");

    const { storage: assetStorage } = createStorage(dbDir, storageOptions);        
    const { storage: metadataStorage } = createStorage(options.meta || pathJoin(dbDir, '.db'));

    const database = new MediaFileDatabase(assetStorage, metadataStorage, process.env.GOOGLE_API_KEY);
    await database.create(); 

    log.success(`Created new media file database in "${dbDir}".`);
}