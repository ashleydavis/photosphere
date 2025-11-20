import { IStorage } from "storage";
import { IDatabaseMetadata, ProgressCallback, getDatabaseSummary } from "./media-file-database";
import { computeHash, computeAssetHash } from "./hash";
import { log, retry } from "utils";
import { IMerkleTree, SortNode, traverseTreeAsync } from "merkle-tree";
import { loadMerkleTree } from "./tree";

//
// Options for repairing the media file database.
//
export interface IRepairOptions {
    //
    // The source database path to repair from.
    //
    source: string;
    
    //
    // The source key file.
    //
    sourceKey?: string;
    
    //
    // Enables full verification where all files are re-hashed.
    //
    full?: boolean;    
}

//
// Result of the repair process.
//
export interface IRepairResult {
    //
    // The total number of files imported into the database.
    //
    totalImports: number;

    //
    // The total number of files verified (including thumbnails, display, BSON, etc.).
    //
    totalFiles: number;

    //
    // The total database size.
    //
    totalSize: number;

    //
    // The number of files that were unmodified.
    //
    numUnmodified: number;

    //
    // The list of files that were modified.
    //
    modified: string[];

    //
    // The list of new files that were added to the database.
    //
    new: string[];

    //
    // The list of files that were removed from the database.
    //
    removed: string[];

    //
    // The list of files that were successfully repaired.
    //
    repaired: string[];

    //
    // The list of files that could not be repaired.
    //
    unrepaired: string[];

    //
    // The number of files processed.
    //
    filesProcessed: number;

    //
    // The number of nodes processed in the merkle tree.
    //
    nodesProcessed: number;
}

//
// Repairs the media file database by restoring corrupted or missing files from a source database.
//
export async function repair(
    assetStorage: IStorage, 
    metadataStorage: IStorage, 
    sourceAssetStorage: IStorage,
    options: IRepairOptions, 
    progressCallback?: ProgressCallback
): Promise<IRepairResult> {        
    const summary = await getDatabaseSummary(assetStorage, metadataStorage);
    const result: IRepairResult = {
        totalImports: summary.totalImports,
        totalFiles: summary.totalFiles,
        totalSize: summary.totalSize,
        numUnmodified: 0,
        modified: [],
        new: [],
        removed: [],
        repaired: [],
        unrepaired: [],
        filesProcessed: 0,
        nodesProcessed: 0,
    };

    //
    // Repairs a single file.
    //
    const repairFile = async (fileName: string, expectedHash: Buffer): Promise<boolean> => {
        try {
            // Check if file exists in source
            if (!await sourceAssetStorage.fileExists(fileName)) {
                log.warn(`Source file not found for repair: ${fileName}`);
                return false;
            }

            // Get source file info
            const sourceFileInfo = await sourceAssetStorage.info(fileName);
            if (!sourceFileInfo) {
                log.warn(`Source file info not available: ${fileName}`);
                return false;
            }

            // Verify source file hash matches expected
            const sourceHash = await computeHash(sourceAssetStorage.readStream(fileName));
            if (Buffer.compare(sourceHash, expectedHash) !== 0) {
                log.warn(`Source file hash mismatch for: ${fileName}`);
                return false;
            }

            // Copy file from source to target
            const readStream = sourceAssetStorage.readStream(fileName);

            // 
            // A write lock isn't needed here unless we think multiple repairs might try to operate on the tree at the same time.
            // TODO: Maybe a "repair lock" will be in order at some point in the future.
            //
            await assetStorage.writeStream(fileName, sourceFileInfo.contentType, readStream);

            // Verify copied file
            const copiedFileInfo = await assetStorage.info(fileName);
            if (!copiedFileInfo) {
                log.warn(`Failed to get info for repaired file: ${fileName}`);
                return false;
            }

            const copiedHash = await computeAssetHash(fileName, copiedFileInfo, () => assetStorage.readStream(fileName));
            if (Buffer.compare(copiedHash.hash, expectedHash) !== 0) {
                log.warn(`Repaired file hash mismatch: ${fileName}`);
                return false;
            }

            return true;
        } catch (error: any) {
            log.error(`Error repairing file ${fileName}: ${error.message}`);
            return false;
        }
    };

    //
    // Check nodes in the merkle to find corrupted/missing files.
    //
    const checkFile = async (node: SortNode, merkleTree: IMerkleTree<IDatabaseMetadata>): Promise<void> => {

        result.filesProcessed++;

        if (progressCallback) {
            progressCallback(`Checking file ${result.filesProcessed} of ${summary.totalFiles}`);
        }

        const fileName = node.name!;
        const fileInfo = await assetStorage.info(fileName);
        if (!fileInfo) {
            // File is missing - try to repair.
            if (progressCallback) {
                progressCallback(`Repairing missing file: ${fileName}`);
            }

            const repaired = await repairFile(fileName, node.contentHash!);
            if (repaired) {
                result.repaired.push(fileName);
            } else {
                result.removed.push(fileName);
                result.unrepaired.push(fileName);
            }
            return;
        }

        // Check if file is corrupted.
        if (node.size !== fileInfo.length 
            || node.lastModified!.getTime() !== fileInfo.lastModified.getTime()
            || options.full) {
            
            // Verify the actual hash.
            const freshHash = await computeAssetHash(fileName, fileInfo, () => assetStorage.readStream(fileName));                
            if (Buffer.compare(freshHash.hash, node.contentHash!) !== 0) {
                // File is corrupted - try to repair.
                if (progressCallback) {
                    progressCallback(`Repairing corrupted file: ${fileName}`);
                }

                const repaired = await repairFile(fileName, node.contentHash!);
                if (repaired) {
                    result.repaired.push(fileName);
                } else {
                    result.modified.push(fileName);
                    result.unrepaired.push(fileName);
                }
            } else {
                result.numUnmodified++;
            }
        } else {
            result.numUnmodified++;
        }
    }

    if (progressCallback) {
        progressCallback(`Checking for missing or corrupt files in merkle tree...`);
    }

    const merkleTree = await retry(() => loadMerkleTree(metadataStorage));
    if (!merkleTree) {
        throw new Error(`Failed to load merkle tree`);
    }

    await traverseTreeAsync<SortNode>(merkleTree.sort, async (node) => {
        result.nodesProcessed++;
    
        if (node.name) {
            await checkFile(node, merkleTree);
        }

        return true;
    });

    return result;
}
