//
// Loads a BSON fixture into the database.
//
//TODO: There should be a separate tool that does this.
//      Maybe this can be subsumed into the bdb-cli tool.

import { BsonDatabase } from 'bdb';
import fs from 'fs';
import path from 'path';
import { createStorage } from 'storage';
import { RandomUuidGenerator, TimestampProvider } from 'utils';

async function main(): Promise<void> {
    const rootPath = './files';
    const databaseFixturePath = `${rootPath}/bson`;
    const databasePath = `${rootPath}/database`;    
    await loadFixtures(databaseFixturePath, databasePath);

    const databasesPath = './files/collections';
    const databases = fs.readdirSync(databasesPath);
    for (const databaseId of databases) {
        const setPath = `${databasesPath}/${databaseId}`;
        const fixturesPath = `${setPath}/bson`;
        const databasePath = `${setPath}/metadata`;
        await loadFixtures(fixturesPath, databasePath);
    }
}

main()
    .then(() => {
        console.log('Done');
    })
    .catch((err) => {
        console.error(`Failed to load BSON data fixture.`);
        console.error(err.stack || err.message || err);
        process.exit(1);
    });

//
// Loads a single fixture file into a database.
// The name of the file is used as the collection name.
//
async function loadFixture(fixturesPath: string, file: string, bsonDatabase: BsonDatabase): Promise<void> {
    console.log(`Loading fixture ${fixturesPath}/${file}`);
    const fullPath = path.resolve(`${fixturesPath}/${file}`);
    const records = require(fullPath);
    const collectionName = file.replace('.js', '');
    const collection = bsonDatabase.collection(collectionName);
    
    // Generate indexes for metadata collection (used by photosphere)
    if (collectionName === 'metadata') {
        await collection.ensureSortIndex("hash", "asc", "string");
        await collection.ensureSortIndex("photoDate", "desc", "date");
    }

    for (const record of records) {
        await collection.insertOne(record);
    }
    
}

//
// Loads all BSON fixtures in a directory into the database.
//
async function loadFixtures(fixturesPath: string, databasePath: string): Promise<void> {
    
    const files = fs.readdirSync(fixturesPath);
    const { storage } = await createStorage(databasePath);
    const bsonDatabase = new BsonDatabase({ storage, uuidGenerator: new RandomUuidGenerator(), timestampProvider: new TimestampProvider() });

    for (const file of files) {
        if (file.endsWith(".js")) {
            await loadFixture(fixturesPath, file, bsonDatabase);
        }
    }
}
