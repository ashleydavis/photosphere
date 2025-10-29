//
// Result of the replication process.

import { computeHash } from "adb";
import { IStorage } from "storage";
import { retry } from "utils";
import { MediaFileDatabase, ProgressCallback } from "./media-file-database";
import { buildMerkleTree, getItemInfo, saveTree, SortNode, traverseTreeAsync, upsertItem } from "merkle-tree";
import { loadMerkleTree, loadOrCreateMerkleTree } from "./tree";

//
export interface IReplicationResult {
    //
    // The total number of files imported.
    //
    filesImported: number;

    //
    // The total number of files considered.
    //
    filesConsidered: number;

    //
    // The number of files already existing in the destination storage.
    //
    existingFiles: number;

    //
    // The number of files copied to the destination storage.
    //
    copiedFiles: number;
}

//
// Options for the replication process.
//
export interface IReplicateOptions {
    //
    // Path filter to only replicate files matching this path (file or directory).
    //
    pathFilter?: string;
}

//
// Replicates the media file database to another storage.
//
export async function replicate(mediaFileDatabase: MediaFileDatabase, destAssetStorage: IStorage, destMetadataStorage: IStorage, options?: IReplicateOptions, progressCallback?: ProgressCallback): Promise<IReplicationResult> {

    const merkleTree = await retry(() => loadMerkleTree(mediaFileDatabase.getMetadataStorage()));
    if (!merkleTree) {
        throw new Error(`Failed to load merkle tree`);
    }

    const filesImported = merkleTree.databaseMetadata?.filesImported || 0;

    const result: IReplicationResult = {
        filesImported,
        filesConsidered: 0,
        existingFiles: 0,
        copiedFiles: 0,
    };

    //
    // Load the destination database, or create it if it doesn't exist.
    //
    let destMerkleTree = await loadOrCreateMerkleTree(destMetadataStorage, mediaFileDatabase.uuidGenerator);
    
    //
    // Copy database metadata from source to destination.
    //
    if (merkleTree.databaseMetadata) {
        destMerkleTree.databaseMetadata = { ...merkleTree.databaseMetadata };
    }

    //
    // Copies an asset from the source storage to the destination storage.
    // But only when necessary.
    //
    const copyAsset = async (fileName: string, sourceHash: Buffer): Promise<void> => {
        result.filesConsidered++;
        
        // Check if file already exists in destination tree with matching hash.
        const destFileInfo = getItemInfo(destMerkleTree!, fileName);
        if (destFileInfo && Buffer.compare(destFileInfo.hash, sourceHash) === 0) {
            // File already exists with correct hash, skip copying.
            // This assumes the file is non-corrupted. To find corrupted files, a verify would be needed.
            result.existingFiles++;
            if (progressCallback) {
                progressCallback(`Copied ${result.copiedFiles} | Already copied ${result.existingFiles}`);
            }
            return;
        }

        const assetStorage = mediaFileDatabase.getAssetStorage();
        const srcFileInfo = await retry(() => assetStorage.info(fileName));
        if (!srcFileInfo) {
            throw new Error(`Source file "${fileName}" does not exist in the source database.`);
        }

        //
        // Copy the file from source to dest.
        //
        await retry(async  () => {
            const readStream = assetStorage.readStream(fileName);
            await destAssetStorage.writeStream(fileName, srcFileInfo.contentType, readStream);
        });

        //
        // Compute hash for the copied file.
        //
        const copiedHash = await retry(() => computeHash(destAssetStorage.readStream(fileName)));
        if (Buffer.compare(copiedHash, sourceHash) !== 0) {
            throw new Error(
`Copied file "${fileName}" hash does not match the source hash.
Source hash: ${sourceHash.toString("hex")}
Copied hash: ${copiedHash.toString("hex")}
`);
        }

        //
        // Get the info for the copied file.
        //
        const copiedFileInfo = await retry(() => destAssetStorage.info(fileName));
        if (!copiedFileInfo) {
            throw new Error(`Failed to read dest info for file: ${fileName}`);
        }

        //
        // Add or update the file in the destination merkle tree.
        //
        if (!fileName.startsWith("metadata/")) {
            destMerkleTree = upsertItem(destMerkleTree!, {
                name: fileName,
                hash: copiedHash,
                length: copiedFileInfo.length,
                lastModified: copiedFileInfo.lastModified,
            });
        }

        result.copiedFiles++;

        if (progressCallback) {
            progressCallback(`Copied ${result.copiedFiles} | Already copied ${result.existingFiles}`);
        }
    };

    //
    // Process a node in the soure merkle tree.
    //
    const processSrcNode = async (srcNode: SortNode): Promise<boolean> => {
        if (srcNode.name) {
            // Skip files that don't match the path filter
            if (options?.pathFilter) {
                const pathFilter = options.pathFilter.replace(/\\/g, '/'); // Normalize path separators
                const fileName = srcNode.name.replace(/\\/g, '/');
                
                // Check if the file matches the filter (exact match or starts with filter + '/')
                if (fileName !== pathFilter && !fileName.startsWith(pathFilter + '/')) {
                    return true; // Continue traversal
                }
            }
                            
            await retry(() => copyAsset(srcNode.name!, srcNode.contentHash!));

            if (result.copiedFiles % 100 === 0) {
                // Save the destination merkle tree periodically
                await retry(async () => {
                    if (destMerkleTree.dirty) {
                        destMerkleTree.merkle = buildMerkleTree(destMerkleTree.sort);
                        destMerkleTree.dirty = false;
                    }
                    await saveTree("tree.dat", destMerkleTree, destMetadataStorage);
                });
            }
        }
        return true; // Continue traversing.
    };

    await traverseTreeAsync<SortNode>(merkleTree.sort, processSrcNode);

    //
    // Saves the dest database.
    //
    await retry(async () => {
        if (destMerkleTree.dirty) {
            destMerkleTree.merkle = buildMerkleTree(destMerkleTree.sort);
            destMerkleTree.dirty = false;
        }
        await saveTree("tree.dat", destMerkleTree, destMetadataStorage);
    });
    
    return result;
}
