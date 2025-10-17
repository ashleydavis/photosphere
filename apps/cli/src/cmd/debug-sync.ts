import { loadDatabase, IBaseCommandOptions } from "../lib/init-cmd";
import { log, retry } from "utils";
import pc from "picocolors";
import { MediaFileDatabase } from "api";
import { IStorage } from "storage";
import { MerkleNode, traverseTree, getFileInfo, computeHash, addFile } from "adb";

//
// Options for the debug sync command.
//
export interface IDebugSyncCommandOptions extends IBaseCommandOptions {
    dest: string;
    destMeta?: string;
}

//
// Debug sync command implementation - synchronizes databases according to the sync specification.
//
export async function debugSyncCommand(options: IDebugSyncCommandOptions): Promise<void> {

    log.info("Starting database sync operation...");
    log.info(`  Source:    ${pc.cyan(options.db || ".")}`);
    log.info(`  Target:    ${pc.cyan(options.dest)}`);
    log.info("");

    const { database: sourceDb } = await loadDatabase(options.db, options, false, false);
    const targetOptions = { ...options, db: options.dest, meta: options.destMeta };
    const { database: targetDb } = await loadDatabase(targetOptions.db, targetOptions, false, false);
    await syncAllDevices(sourceDb, targetDb);
        
    log.info("Sync completed successfully!");       
}

//
// Gets list of other devices from target database by scanning the devices folder.
//
async function* iterateDevices(metadataStorage: IStorage): AsyncGenerator<string> {
    let next: string | undefined = undefined;
    do {

        const listResult = await metadataStorage.listDirs("devices/", 1000, next);
        for (const deviceId of listResult.names) {
            yield deviceId;
        }
        next = listResult.next;

    } while (next);    
}

//
// Syncs all devices between source and target databases.
// Source device gets bidirectional sync, other devices get pull-only.
//
async function syncAllDevices(sourceDb: MediaFileDatabase, targetDb: MediaFileDatabase): Promise<void> {

    //
    // Pull incoming files.
    //
    
    await sourceDb.acquireWriteLock(); //todo: Two write locks here in turn, deadlocks? todo: Don't need write lock if nothing to pull.
    try {
        // Push files from target to source (effectively pulls files from target into source).
        // We are pulling files into the sourceDb, so need the write lock on the source db.
        await pushFiles(targetDb, sourceDb);

        await sourceDb.updateToLatestBlocks(); //todo: only really want to do this if the database has `metadata/` directory.
    }
    finally {
        await sourceDb.releaseWriteLock();
    }

    //
    // Push outgoing files.
    //

    await targetDb.acquireWriteLock(); //todo: Don't need write lock if nothing to push.
    try {
        // Push files from source to target.
        // Need the write lock in the target database.
        await pushFiles(sourceDb, targetDb);
    } 
    finally {
        await targetDb.releaseWriteLock();
    }
}

//
// Pushes from source db to target db for a particular device based
// on missing files detected by comparing source and target merkle trees.
//
// TODO: Need a faster algorithm to traverse each tree comparing nodes and trying to make them the same.
//
async function pushFiles(sourceDb: MediaFileDatabase, targetDb: MediaFileDatabase): Promise<void> {
    const sourceMerkleTree = sourceDb.getAssetDatabase().getMerkleTree();
    const targetAssetDatabase = targetDb.getAssetDatabase();
    const targetMerkleTree = targetAssetDatabase.getMerkleTree();
    const sourceStorage = sourceDb.getAssetStorage();
    const targetStorage = targetDb.getAssetStorage();
   
    let filesCopied = 0;
    let filesProcessed = 0;

    // 
    // Copies a single file if necessary.
    //
    const copyFile = async (fileName: string, sourceHash: Buffer, sourceSize: number, sourceModified: Date): Promise<void> => {
        const targetFileInfo = getFileInfo(targetMerkleTree!, fileName);        
        if (targetFileInfo) {
            // File exists and so there is no need to copy it.
            // Just assume the target file is the same and ok. 
            // If it were different, it could only be from corruption, because files are immutable.
            // If the file is corrupted a verify/repair is needed.
            return;
        }

        // Get file info from source.
        const sourceFileInfo = await sourceStorage.info(fileName);
        if (!sourceFileInfo) {
            throw new Error(`Failed to find file ${fileName} in source database.`);
        }
        
        // Copy file from source to target.
        const readStream = sourceStorage.readStream(fileName);
        await targetStorage.writeStream(fileName, sourceFileInfo.contentType, readStream);

        const copiedFileInfo = await targetStorage.info(fileName);
        if (!copiedFileInfo) {
            throw new Error(`Failed to copy ${fileName} to target db.`);
        }

        const copiedFileHash = await computeHash(targetStorage.readStream(fileName));
        if (Buffer.compare(copiedFileHash, sourceHash) !== 0) {
            throw new Error(`Hash of copied file ${fileName} is different to the source hash.`);            
        }
        
        // Add file to target merkle tree.
        targetDb.getAssetDatabase().addFile(fileName, {
            hash: copiedFileHash,
            length: copiedFileInfo.length,
            lastModified: copiedFileInfo.lastModified,
        });

        filesCopied++;
        
        log.verbose(`Copied file: ${fileName}`);
    };
    
    // Walk the source merkle tree.
    await traverseTree(sourceMerkleTree, async (node: MerkleNode): Promise<boolean> => {
        if (!node.fileName || node.isDeleted) {
            // Skip intermediate nodes.
            return true;
        }

        filesProcessed++;

        // Copy file to target, if necessary.
        await retry(() => copyFile(node.fileName!, node.hash, node.size, node.lastModified!));
        
        // Save target merkle tree every 100 files.
        if (filesCopied % 100 === 0) {
            await retry(()  => targetAssetDatabase.save());
        }
        
        return true;
    });
    
    // Save the target merkle tree one final time.
    await retry(()  => targetAssetDatabase.save());
    
    log.info(`Push completed: ${filesCopied} files copied out of ${filesProcessed} processed`);
}

