import { MediaFileDatabase } from "api";
import { createStorage, loadEncryptionKeys, pathJoin } from "storage";
import { log } from "utils";

//
// Adds files and directories to the Photosphere media file database.
//
export async function addCommand(dbDir: string, paths: string[], options: any): Promise<void> {

    const { options: storageOptions } = await loadEncryptionKeys(options.key, options.generateKey || false, "source");

    const { storage: assetStorage } = createStorage(dbDir, storageOptions);
    const { storage: metadataStorage } = createStorage(options.meta || pathJoin(dbDir, '.db'));

    const database = new MediaFileDatabase(assetStorage, metadataStorage, process.env.GOOGLE_API_KEY);
    await database.load();

    await database.addPaths(paths);

    await database.close();

    log.success(`Added files to the media database.`);

    const addSummary = database.getAddSummary();

    log.info(`Details: `);
    log.info(`  - ${addSummary.numFilesAdded} files added.`);
    log.info(`  - ${addSummary.numFilesIgnored} files ignored.`);
    log.info(`  - ${addSummary.numFilesFailed} files failed to be added.`);
    log.info(`  - ${addSummary.numFilesAlreadyAdded} files already in the database.`);
    log.info(`  - ${addSummary.totalSize} bytes added to the database.`);
    log.info(`  - ${addSummary.averageSize} bytes average size.`);
}