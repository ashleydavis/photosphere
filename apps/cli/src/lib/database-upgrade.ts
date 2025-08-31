import { log } from "utils";
import pc from "picocolors";
import { CURRENT_DATABASE_VERSION, HashCache } from "adb";
import { pathJoin } from "storage";
import type { MediaFileDatabase } from "api";
import type { IStorage } from "storage";

//
// Performs the actual database upgrade logic for a database from a given version to the current version.
//
export async function performDatabaseUpgrade(
    database: MediaFileDatabase, 
    metadataStorage: IStorage, 
    readonly: boolean
): Promise<void> {

    const merkleTree = database.getAssetDatabase().getMerkleTree();
    const currentVersion = merkleTree.version;
   
    // For any upgrade from version 2, copy file metadata from hash cache to merkle tree
    if (currentVersion === 2) {        
        // Load the hash cache
        const hashCache = new HashCache(metadataStorage, "", false);
        const cacheLoaded = await hashCache.load();        
        if (cacheLoaded) {
            // Get the merkle tree and update leaf nodes with file metadata
            const assetDb = database.getAssetDatabase();
            const merkleTree = assetDb.getMerkleTree();
            
            // Track how many files we updated
            let filesUpdated = 0;
            
            // Update leaf nodes with lastModified from hash cache
            for (const node of merkleTree.nodes) {
                if (node.fileName) { // This is a leaf node
                    const cacheEntry = hashCache.getHash(node.fileName);
                    if (cacheEntry) {
                        node.lastModified = cacheEntry.lastModified;
                        filesUpdated++;
                    }
                }
            }
        }
               
        const assetStorage = database.getAssetStorage();

        for (const node of merkleTree.nodes) {
            if (node.fileName && !node.lastModified) {
                const fileInfo = await assetStorage.info(node.fileName);
                if (fileInfo) {
                    // Fill in missing lastModified from file info
                    node.lastModified = fileInfo.lastModified;
                }
            }
        }        
    }

    // Initialize database metadata for any version upgrade
    const assetDb = database.getAssetDatabase();
    const updatedMerkleTree = assetDb.getMerkleTree();
    
    // Count files in the assets directory to get the actual number of imported files
    const assetStorage = database.getAssetStorage();
    let filesImported = 0;
    let next: string | undefined = undefined;
    
    do {
        const assetFiles = await assetStorage.listFiles("asset", 1000, next);
        filesImported += assetFiles.names.length;
        next = assetFiles.next;
    } while (next);
    
    if (!updatedMerkleTree.databaseMetadata) {
        updatedMerkleTree.databaseMetadata = { filesImported };
    }
    else {
        updatedMerkleTree.databaseMetadata.filesImported = filesImported;
    }
    
    if (!readonly) {
        // Save the database - this will write in the latest format
        await database.getAssetDatabase().save();

        // Delete old files after successful upgrade.
        await metadataStorage.deleteFile("hash-cache-x.dat");
        await metadataStorage.deleteFile("metadata.json");
    }    
}