//
// Loads a BSON fixture into the database.
//
//TODO: There should be a separate tool that does this.

import fs from 'fs';
import path from 'path';
import { BsonDatabase, FileStorage } from 'storage';

async function main() {
    const rootPath = './files/collections';
    const sets = fs.readdirSync(rootPath);
    for (const setId of sets) {
        const setPath = `${rootPath}/${setId}`;
        const fixturesPath = `${setPath}/bson`;
        const files = fs.readdirSync(fixturesPath);
    
        const storage = new FileStorage();
        const bsonDatabase = new BsonDatabase({
            storage,
            directory: `${setPath}/metadata`,
        });

        try {
            for (const file of files) {
                if (file.endsWith(".js")) {              
                    const fullPath = path.resolve(`${fixturesPath}/${file}`);
                    const records = require(fullPath);
                    const collectionName = file.replace('.js', '');
                    const collection = bsonDatabase.collection(collectionName);
                    for (const record of records) {
                        await collection.insertOne(record);                        
                    }
                }
            }
        }
        finally {
            await bsonDatabase.shutdown();
        }
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