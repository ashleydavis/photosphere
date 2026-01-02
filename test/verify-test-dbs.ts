//
// Verifies that generated test databases match the original fixtures
//

import { createMediaFileDatabase, loadDatabase } from 'api';
import { createStorage } from 'storage';
import { RandomUuidGenerator, TimestampProvider } from 'utils';
import fs from 'fs';
import path from 'path';
import crypto from 'crypto';

async function main(): Promise<void> {
    const fixturesPath = path.resolve('./test/fixtures');
    const dbsPath = path.resolve('./test/dbs');

    if (!fs.existsSync(fixturesPath)) {
        console.error(`Fixtures directory not found: ${fixturesPath}`);
        process.exit(1);
    }

    const fixtures = fs.readdirSync(fixturesPath);
    let allPassed = true;
    
    for (const fixtureName of fixtures) {
        const fixturePath = path.join(fixturesPath, fixtureName);
        const stat = fs.statSync(fixturePath);
        
        if (!stat.isDirectory()) {
            continue;
        }

        console.log(`\nVerifying fixture: ${fixtureName}`);
        
        const fixtureFilesPath = path.join(fixturePath, 'files');
        const collectionsPath = path.join(fixtureFilesPath, 'collections');
        
        if (fs.existsSync(collectionsPath)) {
            const collections = fs.readdirSync(collectionsPath);
            for (const databaseId of collections) {
                const collectionPath = path.join(collectionsPath, databaseId);
                const stat = fs.statSync(collectionPath);
                
                if (!stat.isDirectory()) {
                    continue;
                }

                const dbPath = collections.length === 1 
                    ? path.join(dbsPath, fixtureName)
                    : path.join(dbsPath, fixtureName, databaseId);
                
                if (!fs.existsSync(dbPath)) {
                    console.error(`  ✗ Database not found: ${dbPath}`);
                    allPassed = false;
                    continue;
                }

                const passed = await verifyCollection(collectionPath, dbPath, databaseId);
                if (!passed) {
                    allPassed = false;
                }
            }
        }
        else {
            // Empty database
            const dbPath = path.join(dbsPath, fixtureName);
            if (!fs.existsSync(dbPath)) {
                console.error(`  ✗ Database not found: ${dbPath}`);
                allPassed = false;
                continue;
            }
            
            console.log(`  ✓ Empty database exists: ${dbPath}`);
        }
    }

    if (allPassed) {
        console.log('\n✓ All databases verified successfully!');
        process.exit(0);
    }
    else {
        console.error('\n✗ Some databases failed verification');
        process.exit(1);
    }
}

async function verifyCollection(
    fixtureCollectionPath: string,
    dbPath: string,
    databaseId: string
): Promise<boolean> {
    console.log(`  Verifying collection: ${databaseId}`);
    let allChecksPassed = true;

    // 1. Verify metadata records
    const bsonPath = path.join(fixtureCollectionPath, 'bson');
    const metadataFile = path.join(bsonPath, 'metadata.js');
    
    if (fs.existsSync(metadataFile)) {
        const fixtureRecords = require(metadataFile);
        const fixtureRecordCount = fixtureRecords.length;
        
        // Load database and count records
        const uuidGenerator = new RandomUuidGenerator();
        const timestampProvider = new TimestampProvider();
        const { storage: assetStorage } = createStorage(dbPath);
        const database = createMediaFileDatabase(assetStorage, uuidGenerator, timestampProvider);
        await loadDatabase(assetStorage, database.metadataCollection);
        
        let dbRecordCount = 0;
        const dbRecords = new Map<string, any>();
        // Use getAll to get records in external format
        let next: string | undefined = undefined;
        do {
            const result = await database.metadataCollection.getAll(next);
            for (const record of result.records) {
                dbRecordCount++;
                dbRecords.set(record._id, record);
            }
            next = result.next;
        } while (next);
        
        if (dbRecordCount !== fixtureRecordCount) {
            console.error(`    ✗ Record count mismatch: fixture has ${fixtureRecordCount}, database has ${dbRecordCount}`);
            allChecksPassed = false;
        }
        else {
            console.log(`    ✓ Record count matches: ${fixtureRecordCount}`);
        }
        
        // Verify each record
        for (const fixtureRecord of fixtureRecords) {
            const dbRecord = dbRecords.get(fixtureRecord._id);
            if (!dbRecord) {
                console.error(`    ✗ Record ${fixtureRecord._id} not found in database`);
                allChecksPassed = false;
                continue;
            }
            
            // Compare key fields (excluding internal fields like _createdAt, _updatedAt)
            const fieldsToCheck = ['_id', 'origFileName', 'contentType', 'width', 'height', 'hash', 'fileDate', 'photoDate'];
            for (const field of fieldsToCheck) {
                const fixtureValue = fixtureRecord[field];
                const dbValue = dbRecord[field];
                
                if (field === 'fileDate' || field === 'photoDate') {
                    const fixtureDate = fixtureValue instanceof Date ? fixtureValue.getTime() : new Date(fixtureValue).getTime();
                    const dbDate = dbValue instanceof Date ? dbValue.getTime() : new Date(dbValue).getTime();
                    if (Math.abs(fixtureDate - dbDate) > 1000) { // Allow 1 second difference
                        console.error(`    ✗ Record ${fixtureRecord._id} field ${field} mismatch`);
                        allChecksPassed = false;
                    }
                }
                else if (fixtureValue !== dbValue) {
                    console.error(`    ✗ Record ${fixtureRecord._id} field ${field} mismatch: "${fixtureValue}" vs "${dbValue}"`);
                    allChecksPassed = false;
                }
            }
        }
        
        if (allChecksPassed) {
            console.log(`    ✓ All metadata records match`);
        }
    }

    // 2. Verify asset files
    const assetTypes = ['asset', 'display', 'thumb'];
    for (const assetType of assetTypes) {
        const fixtureAssetDir = path.join(fixtureCollectionPath, assetType);
        const dbAssetDir = path.join(dbPath, assetType);
        
        if (fs.existsSync(fixtureAssetDir)) {
            const fixtureFiles = fs.readdirSync(fixtureAssetDir).filter(f => {
                const filePath = path.join(fixtureAssetDir, f);
                return fs.statSync(filePath).isFile();
            });
            
            if (!fs.existsSync(dbAssetDir)) {
                console.error(`    ✗ ${assetType} directory not found in database`);
                allChecksPassed = false;
                continue;
            }
            
            const dbFiles = fs.readdirSync(dbAssetDir).filter(f => {
                const filePath = path.join(dbAssetDir, f);
                return fs.statSync(filePath).isFile();
            });
            
            if (fixtureFiles.length !== dbFiles.length) {
                console.error(`    ✗ ${assetType} file count mismatch: fixture has ${fixtureFiles.length}, database has ${dbFiles.length}`);
                allChecksPassed = false;
                continue;
            }
            
            // Verify each file exists and matches
            for (const fileName of fixtureFiles) {
                const fixtureFilePath = path.join(fixtureAssetDir, fileName);
                const dbFilePath = path.join(dbAssetDir, fileName);
                
                if (!fs.existsSync(dbFilePath)) {
                    console.error(`    ✗ ${assetType} file ${fileName} not found in database`);
                    allChecksPassed = false;
                    continue;
                }
                
                // Compare file hashes
                const fixtureHash = computeFileHash(fixtureFilePath);
                const dbHash = computeFileHash(dbFilePath);
                
                if (fixtureHash !== dbHash) {
                    console.error(`    ✗ ${assetType} file ${fileName} hash mismatch`);
                    allChecksPassed = false;
                }
            }
            
            if (allChecksPassed) {
                console.log(`    ✓ ${assetType} files match (${fixtureFiles.length} files)`);
            }
        }
    }

    if (allChecksPassed) {
        console.log(`  ✓ Collection ${databaseId} verified successfully`);
    }

    return allChecksPassed;
}

function computeFileHash(filePath: string): string {
    const fileBuffer = fs.readFileSync(filePath);
    return crypto.createHash('sha256').update(fileBuffer).digest('hex');
}

main()
    .catch((err) => {
        console.error(`Failed to verify test databases.`);
        console.error(err.stack || err.message || err);
        process.exit(1);
    });

