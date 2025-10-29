import { log, retry } from "utils";
import { HashCache, computeHash } from "adb";
import { pathJoin } from "storage";
import { IDatabaseMetadata, loadMerkleTree, saveMerkleTree, type MediaFileDatabase } from "api";
import type { IStorage } from "storage";
import { rebuildTree, SortNode, traverseTreeAsync } from "merkle-tree";

//
// Performs the actual database upgrade logic for a database from a given version to the current version.
//
export async function performDatabaseUpgrade(
    database: MediaFileDatabase, 
    metadataStorage: IStorage, 
    readonly: boolean
): Promise<void> {

    //todo: Need the write lock!

    let merkleTree = await retry(() => loadMerkleTree(database.getMetadataStorage()));
    if (!merkleTree) {
        throw new Error(`Failed to load merkle tree.`);
    }
    const currentVersion = merkleTree.version;
   
    // For any upgrade from version 2, copy file metadata from hash cache to merkle tree
    if (currentVersion === 2) {        
               
        const assetStorage = database.getAssetStorage();

        // Fill in missing lastModified from file info using async binary tree traversal
        await traverseTreeAsync<SortNode>(merkleTree.sort, async (node) => {
            if (node.name) {
                if (!node.lastModified) {
                    const fileInfo = await assetStorage.info(node.name);
                    if (fileInfo) {
                        // Fill in missing lastModified from file info
                        node.lastModified = fileInfo.lastModified;
                    }
                }
            }
            return true; // Continue traversal
        });        
    }

    // Move files from "assets" directory to "asset" directory if they exist
    const assetStorage = database.getAssetStorage();
    if (await assetStorage.fileExists("assets")) {
        log.info("Moving files from 'assets' directory to 'asset' directory...");
        
        let next: string | undefined = undefined;
        let filesMoved = 0;
        
        do {
            const assetsFiles = await assetStorage.listFiles("assets", 1000, next);
            
            for (const fileName of assetsFiles.names) {
                const sourceFile = pathJoin("assets", fileName);
                const destFile = pathJoin("asset", fileName);
                
                // Get file info and compute hash of source file
                const fileInfo = await assetStorage.info(sourceFile);
                if (fileInfo) {
                    const sourceHash = await computeHash(assetStorage.readStream(sourceFile));
                    
                    // Copy file from assets/ to asset/
                    const readStream = assetStorage.readStream(sourceFile);
                    await assetStorage.writeStream(destFile, fileInfo.contentType, readStream);
                    
                    // Verify the copied file has the same hash
                    const destHash = await computeHash(assetStorage.readStream(destFile));
                    
                    if (sourceHash.toString('hex') !== destHash.toString('hex')) {
                        throw new Error(`Hash mismatch during file move from ${sourceFile} to ${destFile}: source=${sourceHash.toString('hex')}, dest=${destHash.toString('hex')}`);
                    }
                    
                    // Only delete the source file after successful verification
                    await assetStorage.deleteFile(sourceFile);
                    filesMoved++;
                }
            }
            
            next = assetsFiles.next;
        } while (next);
        
        log.info(`✓ Moved ${filesMoved} files from 'assets' to 'asset' directory`);
    }

    //
    // Remove metadata files.
    //
    merkleTree = rebuildTree<IDatabaseMetadata>(merkleTree, "metadata/");

    // Count files in the asset directory to get the actual number of imported files
    let filesImported = 0;
    let next: string | undefined = undefined;
    
    do {
        const assetFiles = await assetStorage.listFiles("asset", 1000, next);
        filesImported += assetFiles.names.length;
        next = assetFiles.next;
    } while (next);
    
    if (!merkleTree.databaseMetadata) {
        merkleTree.databaseMetadata = { filesImported };
    }
    else {
        merkleTree.databaseMetadata.filesImported = filesImported;
    }
    
    if (!readonly) {
        // Save the database - this will write in the latest format
        await saveMerkleTree(merkleTree, database.getMetadataStorage());

        // Delete old files after successful upgrade.
        await metadataStorage.deleteFile("hash-cache-x.dat");
        await metadataStorage.deleteFile("metadata.json");
    }    
}
