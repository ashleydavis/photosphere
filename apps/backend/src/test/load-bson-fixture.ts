//
// Loads a BSON fixture into the database.
//
//TODO: There should be a separate tool that does this.

import fs from 'fs';
import path from 'path';
import { BsonDatabase, createStorage, FileStorage } from 'storage';

async function main(): Promise<void> {
    const rootPath = './files';
    const databaseFixturePath = `${rootPath}/bson`;
    const databasePath = `${rootPath}/database`;    
    await loadFixtures(databaseFixturePath, databasePath);

    const setsPath = './files/collections';
    const sets = fs.readdirSync(setsPath);
    for (const setId of sets) {
        const setPath = `${setsPath}/${setId}`;
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
    const fullPath = path.resolve(`${fixturesPath}/${file}`);
    const records = require(fullPath);
    const collectionName = file.replace('.js', '');
    const collection = bsonDatabase.collection(collectionName);
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
    const bsonDatabase = new BsonDatabase({ storage });

    try {
        for (const file of files) {
            if (file.endsWith(".js")) {
                await loadFixture(fixturesPath, file, bsonDatabase);
            }
        }
    }
    finally {
        await bsonDatabase.close();
    }
}
