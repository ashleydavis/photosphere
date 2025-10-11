import { log } from "utils";
import pc from "picocolors";
import { CURRENT_DATABASE_VERSION, HashCache, computeHash, saveTree, deleteFiles, IBlock } from "adb";
import { pathJoin } from "storage";
import type { MediaFileDatabase } from "api";
import type { IStorage } from "storage";
import { BlockGraph, DatabaseUpdate, IUpsertUpdate } from "adb";
import { generateDeviceId } from "node-utils";
import { v4 as uuid } from 'uuid';

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

    // Count files in the asset directory to get the actual number of imported files
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

//
// Build a block graph that contains all updates needed to rebuild the current BSON database
//
export async function buildBlockGraph(database: MediaFileDatabase): Promise<void> {
    log.info("Building block graph from current database state...");
    
    // Use the existing AssetDatabaseStorage to automatically update merkle tree when blocks are written
    const assetStorage = database.getAssetStorage();
    
    // Initialize block graph with the asset storage
    const blockGraph = new BlockGraph<DatabaseUpdate>(assetStorage);
    await blockGraph.loadHeadBlocks();

    // Get the BSON database
    const bsonDatabase = database.getMetadataDatabase();
    const currentTimestamp = Date.now();
    
    // Create upsert operations for all database records
    const databaseUpdates: DatabaseUpdate[] = [];
    let totalRecords = 0;
    
    // Get all collections in the database
    const collectionNames = await bsonDatabase.collections();
    
    log.info(`Found ${collectionNames.length} collections: ${collectionNames.join(', ')}`);
    
    // Iterate through each collection
    for (const collectionName of collectionNames) {
        if (collectionName === "sort_indexes") {
            continue;
        }

        log.info(`Processing collection: ${collectionName}`);
        
        const collection = bsonDatabase.collection(collectionName);
        let recordCount = 0;
        
        // Iterate through all records in the collection
        for await (const record of collection.iterateRecords()) {
            const upsertUpdate: IUpsertUpdate = {
                type: "upsert",
                timestamp: currentTimestamp,
                collection: collectionName,
                _id: record._id,
                document: record
            };
            
            databaseUpdates.push(upsertUpdate);
            recordCount++;
            totalRecords++;
        }
        
        log.info(`✓ Processed ${recordCount} records from collection '${collectionName}'`);
    }

    // Commit the block containing all database updates
    const block = await blockGraph.commitBlock(databaseUpdates);

    log.info(`✓ Block graph created with block ID: ${block._id}`);
    log.info(`✓ Block graph saved to metadata storage`);
    log.info(`✓ Block contains ${databaseUpdates.length} upsert operations from ${collectionNames.length} collections (${totalRecords} total records)`);    
}


//
// Remove files from the merkle tree that are intended to be local only and not replicated.
//
export function removeLocalOnlyFiles(database: MediaFileDatabase): void {
    // Remove metadata files from the merkle tree
    log.info("Removing metadata files from merkle tree...");

    const merkleTree = database.getAssetDatabase().getMerkleTree();

    // Find all metadata files to remove
    const filesToRemove = merkleTree.sortedNodeRefs
        .filter(ref => ref.fileName && ref.fileName.startsWith('metadata/'))
        .map(ref => ref.fileName!);

    // Remove all files in a single operation (only if there are files to remove)
    if (filesToRemove.length > 0) {
        const filesRemoved = deleteFiles(merkleTree, filesToRemove);
        log.info(`✓ Removed ${filesRemoved} metadata files from merkle tree`);
    } else {
        log.info(`✓ No metadata files found in merkle tree to remove`);
    }
}
