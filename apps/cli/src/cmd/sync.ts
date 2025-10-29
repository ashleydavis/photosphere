import { loadDatabase, IBaseCommandOptions } from "../lib/init-cmd";
import { log, retry } from "utils";
import pc from "picocolors";
import { loadMerkleTree, loadOrCreateMerkleTree, MediaFileDatabase, saveMerkleTree } from "api";
import { computeHash } from "adb";
import { exit } from "node-utils";
import { acquireWriteLock, releaseWriteLock } from "api/src/lib/write-lock";
import { addItem, getItemInfo, SortNode, traverseTreeAsync } from "merkle-tree";

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
    if (!await acquireWriteLock(sourceDb.getAssetStorage(), sourceDb.sessionId)) { //todo: Don't need write lock if nothing to pull.
        throw new Error(`Failed to acquire write lock for source database.`);
    }

    try {
        // Push files from target to source (effectively pulls files from target into source).
        // We are pulling files into the sourceDb, so need the write lock on the source db.
        await pushFiles(targetDb, sourceDb);
    }
    finally {
        await releaseWriteLock(sourceDb.getAssetStorage());
    }

    //
    // Push outgoing files.
    //
    if (!await acquireWriteLock(targetDb.getAssetStorage(), targetDb.sessionId)) { //todo: Don't need write lock if nothing to push.
        throw new Error(`Failed to acquire write lock for target database.`);
    }

    try {
        // Push files from source to target.
        // Need the write lock in the target database.
        await pushFiles(sourceDb, targetDb);
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
    const sourceStorage = sourceDb.getAssetStorage();
    const targetStorage = targetDb.getAssetStorage();

    //
    // Load the merkle tree.
    //
    const sourceMerkleTree = await retry(() => loadMerkleTree(sourceDb.getMetadataStorage()));
    if (!sourceMerkleTree) {
        throw new Error("Failed to load source merkle tree.");
    }

    let targetMerkleTree = await retry(() => loadOrCreateMerkleTree(targetDb.getMetadataStorage(), targetDb.uuidGenerator));
   
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
        targetMerkleTree = addItem(targetMerkleTree, {
            name: fileName,
            hash: copiedFileHash,
            length: copiedFileInfo.length,
            lastModified: copiedFileInfo.lastModified,
        });

        filesCopied++;
        
        log.verbose(`Copied file: ${fileName}`);
    };
    
    // Walk the source merkle tree.
    //todo: This should traverse the merkle tree, not the sort tree. It can use the efficient algorithm to deliver differences.
    await traverseTreeAsync<SortNode>(sourceMerkleTree.sort, async (node: SortNode): Promise<boolean> => {
        if (!node.name) {
            // Skip intermediate nodes.
            return true;
        }

        filesProcessed++;

        // Copy file to target, if necessary.
        await retry(() => copyFile(node.name!, node.contentHash!, node.size, node.lastModified!));
        
        // Save target merkle tree every 100 files.
        if (filesCopied % 100 === 0) {
            await retry(() => saveMerkleTree(targetMerkleTree, targetDb.getMetadataStorage()))
        }
        
        return true;
    });
    
    // Save the target merkle tree one final time.
    await retry(() => saveMerkleTree(targetMerkleTree, targetDb.getMetadataStorage()))
    
    log.info(`Push completed: ${filesCopied} files copied out of ${filesProcessed} processed`);
}

