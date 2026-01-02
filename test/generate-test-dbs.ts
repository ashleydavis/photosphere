//
// Generates test databases from fixtures in test/fixtures/ into test/dbs/
// Creates databases in the correct Photosphere format matching test/dbs/v5/
//

import { createMediaFileDatabase, createDatabase } from 'api';
import { createStorage } from 'storage';
import { RandomUuidGenerator, TimestampProvider } from 'utils';
import { computeAssetHash } from 'api';
import { addItem, createTree } from 'merkle-tree';
import { loadMerkleTree, saveMerkleTree } from 'api';
import fs from 'fs';
import path from 'path';

async function main(): Promise<void> {
    const fixturesPath = path.resolve('./test/fixtures');
    const dbsPath = path.resolve('./test/dbs');

    // Ensure dbs directory exists
    if (!fs.existsSync(dbsPath)) {
        fs.mkdirSync(dbsPath, { recursive: true });
    }

    if (!fs.existsSync(fixturesPath)) {
        console.error(`Fixtures directory not found: ${fixturesPath}`);
        process.exit(1);
    }

    const fixtures = fs.readdirSync(fixturesPath);
    
    for (const fixtureName of fixtures) {
        const fixturePath = path.join(fixturesPath, fixtureName);
        const stat = fs.statSync(fixturePath);
        
        // Only process directories
        if (!stat.isDirectory()) {
            continue;
        }

        console.log(`Processing fixture: ${fixtureName}`);
        
        const fixtureFilesPath = path.join(fixturePath, 'files');
        
        // Process each collection as a separate database
        const collectionsPath = path.join(fixtureFilesPath, 'collections');
        if (fs.existsSync(collectionsPath)) {
            const collections = fs.readdirSync(collectionsPath);
            for (const databaseId of collections) {
                const collectionPath = path.join(collectionsPath, databaseId);
                const stat = fs.statSync(collectionPath);
                
                if (!stat.isDirectory()) {
                    continue;
                }

                console.log(`  Processing collection: ${databaseId}`);
                
                // Create database directory for this collection
                // For single collection fixtures, use the fixture name, otherwise use collection ID
                const dbPath = collections.length === 1 
                    ? path.join(dbsPath, fixtureName)
                    : path.join(dbsPath, fixtureName, databaseId);
                
                // Remove existing database if it exists
                if (fs.existsSync(dbPath)) {
                    console.log(`    Removing existing database: ${dbPath}`);
                    fs.rmSync(dbPath, { recursive: true, force: true });
                }
                
                // Create database directory
                fs.mkdirSync(dbPath, { recursive: true });

                await createCollectionDatabase(collectionPath, dbPath, databaseId);
            }
        }
        else {
            // No collections, create empty database structure
            const dbPath = path.join(dbsPath, fixtureName);
            if (fs.existsSync(dbPath)) {
                console.log(`  Removing existing database: ${dbPath}`);
                fs.rmSync(dbPath, { recursive: true, force: true });
            }
            fs.mkdirSync(dbPath, { recursive: true });
            
            // Create empty database
            const uuidGenerator = new RandomUuidGenerator();
            const timestampProvider = new TimestampProvider();
            const { storage: assetStorage } = createStorage(dbPath);
            const { storage: metadataStorage } = createStorage(dbPath);
            const database = createMediaFileDatabase(assetStorage, uuidGenerator, timestampProvider);
            await createDatabase(assetStorage, metadataStorage, uuidGenerator, database.metadataCollection);
            console.log(`  ✓ Created empty database: ${dbPath}`);
        }
    }
}

//
// Creates a database for a single collection from fixture data
//
async function createCollectionDatabase(
    collectionPath: string,
    dbPath: string,
    databaseId: string
): Promise<void> {
    const uuidGenerator = new RandomUuidGenerator();
    const timestampProvider = new TimestampProvider();
    
    // Create storage instances
    const { storage: assetStorage } = createStorage(dbPath);
    const { storage: metadataStorage } = createStorage(dbPath);
    
    // Create database instance
    const database = createMediaFileDatabase(assetStorage, uuidGenerator, timestampProvider);
    
    // Create the database structure (merkle tree, README, etc.)
    await createDatabase(assetStorage, metadataStorage, uuidGenerator, database.metadataCollection, databaseId);
    
    // Load metadata from fixture
    const bsonPath = path.join(collectionPath, 'bson');
    if (fs.existsSync(bsonPath)) {
        const metadataFile = path.join(bsonPath, 'metadata.js');
        if (fs.existsSync(metadataFile)) {
            console.log(`    Loading metadata from ${metadataFile}`);
            const records = require(metadataFile);
            
            for (const record of records) {
                await database.metadataCollection.insertOne(record);
            }
        }
    }
    
    // Copy asset files and add them to merkle tree
    let merkleTree = await loadMerkleTree(metadataStorage);
    if (!merkleTree) {
        throw new Error('Failed to load merkle tree after database creation');
    }
    
    // Copy asset files from fixture
    const assetTypes = ['asset', 'display', 'thumb'];
    for (const assetType of assetTypes) {
        const sourceAssetDir = path.join(collectionPath, assetType);
        if (fs.existsSync(sourceAssetDir)) {
            const files = fs.readdirSync(sourceAssetDir);
            for (const fileName of files) {
                const sourcePath = path.join(sourceAssetDir, fileName);
                const stat = fs.statSync(sourcePath);
                
                if (!stat.isFile()) {
                    continue;
                }
                
                const destPath = `${assetType}/${fileName}`;
                
                // Copy file
                const fileBuffer = fs.readFileSync(sourcePath);
                const contentType = assetType === 'asset' 
                    ? 'application/octet-stream' // Will be determined from metadata
                    : 'image/jpeg'; // Display and thumb are always JPEG
                
                await assetStorage.write(destPath, contentType, fileBuffer);
                
                // Get file info and compute hash
                const fileInfo = await assetStorage.info(destPath);
                if (!fileInfo) {
                    throw new Error(`Failed to get info for ${destPath}`);
                }
                
                const hashedAsset = await computeAssetHash(
                    assetStorage.readStream(destPath),
                    fileInfo
                );
                
                // Add to merkle tree
                merkleTree = addItem(merkleTree, {
                    name: destPath,
                    hash: hashedAsset.hash,
                    length: hashedAsset.length,
                    lastModified: hashedAsset.lastModified,
                });
                
                // Update filesImported count for asset files
                if (assetType === 'asset') {
                    if (!merkleTree.databaseMetadata) {
                        merkleTree.databaseMetadata = { filesImported: 0 };
                    }
                    merkleTree.databaseMetadata.filesImported++;
                }
            }
        }
    }
    
    // Save updated merkle tree
    await saveMerkleTree(merkleTree, metadataStorage);
    
    console.log(`    ✓ Created database: ${dbPath}`);
}

main()
    .then(() => {
        console.log('Done');
    })
    .catch((err) => {
        console.error(`Failed to generate test databases.`);
        console.error(err.stack || err.message || err);
        process.exit(1);
    });
