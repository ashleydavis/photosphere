import { formatFileSize, log, retry } from "utils";
import { MediaFileDatabase, ProgressCallback } from "./media-file-database";
import { computeAssetHash } from "./hash";
import { SortNode, traverseTreeAsync } from "merkle-tree";
import { loadMerkleTree } from "./tree";

//
// Options for verifying the media file database.
//


export interface IVerifyOptions {
    //
    // Enables full verification where all files are re-hashed.
    //
    full?: boolean;

    //
    // Path filter to only verify files matching this path (file or directory).
    //
    pathFilter?: string;
}

//
// Result of the verification process.
//
export interface IVerifyResult {
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
    // The number of files that were processed from the file system.
    // 
    filesProcessed: number;

    //
    // The number of nodes processed in the merkle tree.
    //
    nodesProcessed: number;
}

//
// Verifies the media file database.
// Checks for missing files, modified files, and new files.
// If any files are corrupted, this will pick them up as modified.
//
export async function verify(mediaFileDatabase: MediaFileDatabase, options?: IVerifyOptions, progressCallback?: ProgressCallback) : Promise<IVerifyResult> {

    let pathFilter = options?.pathFilter 
        ? options.pathFilter.replace(/\\/g, '/') // Normalize path separators
        : undefined;

    const summary = await mediaFileDatabase.getDatabaseSummary();
    const result: IVerifyResult = {
        totalImports: summary.totalImports,
        totalFiles: summary.totalFiles,
        totalSize: summary.totalSize,
        numUnmodified: 0,
        modified: [],
        new: [],
        removed: [],
        filesProcessed: 0,
        nodesProcessed: 0,
    };

    //
    // Check the merkle tree to find files that have been removed.
    //
    if (progressCallback) {
        progressCallback(`Checking for modified/removed files...`);
    }

    //
    // Checks that a file matches the merkle tree record.
    //
    const verifyFile = async (node: SortNode): Promise<void> => {
        
        const fileName = node.name!;

            if (pathFilter) {
            if (!fileName.startsWith(pathFilter)) {
                return; // Skips files that don't match the path filter.
            }
        }

        result.filesProcessed++;

        if (progressCallback) {
            progressCallback(`Verified file ${result.filesProcessed} of ${summary.totalFiles}`);
        }

        const assetStorage = mediaFileDatabase.getAssetStorage();
        const fileInfo = await assetStorage.info(fileName);
        if (!fileInfo) {
            // The file doesn't exist in the storage.
            log.warn(`File "${fileName}" is missing, even though we just found it by walking the directory.`);
            result.removed.push(fileName);
            return;
        }

        const sizeChanged = node.size !== fileInfo.length;
        const timestampChanged = node.lastModified === undefined || node.lastModified!.getTime() !== fileInfo.lastModified.getTime();             
        if (sizeChanged || timestampChanged) {
            // File metadata has changed - check if content actually changed by computing the hash.
            const freshHash = await computeAssetHash(fileName, fileInfo, () => assetStorage.readStream(fileName));
            if (Buffer.compare(freshHash.hash, node.contentHash!) !== 0) {
                // The file content has actually been modified.
                result.modified.push(fileName);
                
                // Log detailed reasons for modification only if verbose logging is enabled.
                if (log.verboseEnabled) {
                    const reasons: string[] = [];
                    if (sizeChanged) {
                        const oldSize = formatFileSize(node.size);
                        const newSize = formatFileSize(fileInfo.length);
                        reasons.push(`size changed (${oldSize} → ${newSize})`);
                    }
                    if (timestampChanged) {
                        const oldTime = node.lastModified!.toLocaleString();
                        const newTime = fileInfo.lastModified.toLocaleString();
                        reasons.push(`timestamp changed (${oldTime} → ${newTime})`);
                    }
                    reasons.push('content hash changed');
                    log.verbose(`Modified file: ${node.name} - ${reasons.join(', ')}`);
                }
            } 
            else {
                // Content is the same, just metadata changed - cache is already updated by computeHash.
                result.numUnmodified++;
            }
        }
        else if (options?.full) {
            // The file doesn't seem to have changed, but the full verification is requested.
            const freshHash = await computeAssetHash(fileName, fileInfo, () => assetStorage.readStream(fileName));
            if (Buffer.compare(freshHash.hash, node.contentHash!) === 0) {
                // The file is unmodified.
                result.numUnmodified++;
            } 
            else {
                // The file has been modified (content only, since metadata matched).
                result.modified.push(fileName);
                
                // Log detailed reason for modification only if verbose logging is enabled
                if (log.verboseEnabled) {
                    log.verbose(`Modified file: ${node.name} - content hash changed`);
                }
            }
        }
        else {
            result.numUnmodified++;
        }
    }

    const merkleTree = await retry(() => loadMerkleTree(mediaFileDatabase.getMetadataStorage()));
    if (!merkleTree) {
        throw new Error(`Failed to load merkle tree`);
    }

    await traverseTreeAsync<SortNode>(merkleTree.sort, async (node) => {
        result.nodesProcessed++;

        if (node.name) {
            await verifyFile(node);
        }

        return true;
    });
    
    result.nodesProcessed = result.nodesProcessed;

    return result;
}
