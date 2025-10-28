import { loadDatabase, IBaseCommandOptions } from "../lib/init-cmd";
import { log, retry } from "utils";
import pc from "picocolors";
import { MediaFileDatabase } from "api";
import { MerkleNode, traverseTree, getItemInfo, computeHash, SortNode } from "adb";
import { exit } from "node-utils";
import { acquireWriteLock, releaseWriteLock } from "api/src/lib/write-lock";

//
// Options for the sync command.
//
export interface ISyncCommandOptions extends IBaseCommandOptions {
    dest: string;
}

//
// Sync command implementation - synchronizes databases according to the sync specification.
//
export async function syncCommand(options: ISyncCommandOptions): Promise<void> {

    log.info("Starting database sync operation...");
    log.info(`  Source:    ${pc.cyan(options.db || ".")}`);
    log.info(`  Target:    ${pc.cyan(options.dest)}`);
    log.info("");

    const { database: sourceDb } = await loadDatabase(options.db, options, false, false);
    const targetOptions = { ...options, db: options.dest };
    const { database: targetDb } = await loadDatabase(targetOptions.db, targetOptions, false, false);
    await syncDatabases(sourceDb, targetDb);
        
    log.info("Sync completed successfully!");       

    await exit(0);
}

//
// Syncs between source and target databases.
//
async function syncDatabases(sourceDb: MediaFileDatabase, targetDb: MediaFileDatabase): Promise<void> {

    //
    // Pull incoming files.
    //
    //todo: If the write lock can't be acquired, exit with with code 1 and error.
    if (!await acquireWriteLock(sourceDb.getAssetStorage(), sourceDb.sessionId)) { //todo: Don't need write lock if nothing to pull.
        throw new Error(`Failed to acquire write lock for source database.`);
    }

    try {
        //
        // Always reload the database after acquiring the write lock to ensure we have the latest tree.
        //
        if (!await sourceDb.loadMerkleTree()) {
            throw new Error(`Failed to load source merkle tree after acquiring write lock.`);
        }

        // Push files from target to source (effectively pulls files from target into source).
        // We are pulling files into the sourceDb, so need the write lock on the source db.
        await pushFiles(targetDb, sourceDb);

        //
        // Ensure the tree is saved before releasing the lock.
        //
        await retry(() => sourceDb.save()); 
    }
    finally {
        await releaseWriteLock(sourceDb.getAssetStorage());
    }

    //
    // Push outgoing files.
    //
    //todo: If the write lock can't be acquired, exit with with code 1 and error.
    if (!await acquireWriteLock(targetDb.getAssetStorage(), targetDb.sessionId)) { //todo: Don't need write lock if nothing to push.
        throw new Error(`Failed to acquire write lock for target database.`);
    }

    try {
        //
        // Always reload the database after acquiring the write lock to ensure we have the latest tree.
        //
        if (!await targetDb.loadMerkleTree()) {
            throw new Error(`Failed to load target merkle tree after acquiring write lock.`);
        }

        // Push files from source to target.
        // Need the write lock in the target database.
        await pushFiles(sourceDb, targetDb);

        //
        // Ensure the tree is saved before releasing the lock.
        //
        await retry(() => targetDb.save());
    } 
    finally {
        await releaseWriteLock(targetDb.getAssetStorage());
    }
}

//
// Pushes from source db to target db for a particular device based
// on missing files detected by comparing source and target merkle trees.
//
// TODO: Need a faster algorithm to traverse each tree comparing nodes and trying to make them the same.
//
async function pushFiles(sourceDb: MediaFileDatabase, targetDb: MediaFileDatabase): Promise<void> {
    const sourceMerkleTree = sourceDb.getMerkleTree();
    const targetMerkleTree = targetDb.getMerkleTree();
    const sourceStorage = sourceDb.getAssetStorage();
    const targetStorage = targetDb.getAssetStorage();
   
    let filesCopied = 0;
    let filesProcessed = 0;

    // 
    // Copies a single file if necessary.
    //
    const copyFile = async (fileName: string, sourceHash: Buffer, sourceSize: number, sourceModified: Date): Promise<void> => {
        const targetFileInfo = getItemInfo(targetMerkleTree!, fileName);        
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
        targetDb.addFile(fileName, {
            hash: copiedFileHash,
            length: copiedFileInfo.length,
            lastModified: copiedFileInfo.lastModified,
        });

        filesCopied++;
        
        log.verbose(`Copied file: ${fileName}`);
    };
    
    // Walk the source merkle tree.
    await traverseTree(sourceMerkleTree, async (node: SortNode): Promise<boolean> => {
        if (!node.name) {
            // Skip intermediate nodes.
            return true;
        }

        filesProcessed++;

        // Copy file to target, if necessary.
        await retry(() => copyFile(node.name!, node.contentHash!, node.size, node.lastModified!));
        
        // Save target merkle tree every 100 files.
        if (filesCopied % 100 === 0) {
            await retry(()  => targetDb.save());
        }
        
        return true;
    });
    
    // Save the target merkle tree one final time.
    await retry(()  => targetDb.save());
    
    log.info(`Push completed: ${filesCopied} files copied out of ${filesProcessed} processed`);
}

