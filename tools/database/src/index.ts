import { MongoClient } from "mongodb";
import { getImageResolution, resizeImage } from "node-utils";
import { CloudStorage, readAssetWithRetry } from "storage";
import { IAsset } from "defs";
const _ = require("lodash");
const minimist = require("minimist");
const fs = require("fs-extra");
const ColorThief = require("colorthief");

async function main() {
    const argv = minimist(process.argv.slice(2));

    const DB_CONNECTION_STRING = process.env.DB_CONNECTION_STRING;
    if (DB_CONNECTION_STRING === undefined) {
        throw new Error(`Set environment variable DB_CONNECTION_STRING.`);
    }

    const storage = new CloudStorage();

    const client = new MongoClient(DB_CONNECTION_STRING);
    await client.connect();

    const db = client.db("photosphere");

    const query: any = {};

    if (argv.asset) {
        query._id = argv.asset;
    }
    else if (argv.set) {
        query.setId = argv.set;
    }

    const metadataCollection = db.collection<any>("metadata");
    const documentCount = await metadataCollection.countDocuments(query);
    console.log(`Found ${documentCount} documents in the collection.`);

    let numUpdated = 0;
    let numProcessed = 0;
    let numFailed = 0;
    let queryOffset = 0;
    const querySize = 10_000;
    const batchSize = 100;

    while (true) {
        const documents = await metadataCollection.find<IAsset>(query)
            .skip(queryOffset)
            .limit(querySize)
            .toArray();

        if (documents.length === 0) {
            console.log(`No more documents to process.`);
            break;
        }

        queryOffset += documents.length;

        for (const batch of _.chunk(documents, batchSize)) {
            await Promise.all(batch.map(async (document: any) => {

                if (!document.setId) {
                    throw new Error(`Document ${document._id} does not have setId.`);
                }

                if (!document.color) {
                    const fileData = await readAssetWithRetry(storage, document._id, document.setId, "micro");
                    if (!fileData) {
                        throw new Error(`Document ${document._id} does not have micro asset.`);
                    }

                    try {
                        const color = await ColorThief.getColor(fileData);
    
                        await metadataCollection.updateOne({ _id: document._id }, { 
                            $set: { 
                                color,
                            },
                        });
    
                        // console.log(`Processed ${document.setId}/${document._id}.`);

                        numUpdated += 1;
                    }
                    catch (err) {
                        console.error(`Failed to process ${document.setId}/${document._id}.`);
                        console.error(err);
                        console.log(`Defaulting to white`);

                        const color = [255, 255, 255];
    
                        await metadataCollection.updateOne({ _id: document._id }, { 
                            $set: { 
                                color,
                            },
                        });

                        numFailed += 1;
                    }

                }

                numProcessed += 1;
            }));

            console.log(`Processed ${numProcessed} of ${documentCount} documents.`);
        }
    }

    await client.close();

    console.log(`-- Summary --`);
    console.log(`Total documents ${documentCount}.`);
    console.log(`Updated: ${numUpdated}.`);
    console.log(`Processed: ${numProcessed}.`);
    console.log(`Failed: ${numFailed}.`);

    await fs.ensureDir("./log");
    await fs.writeFile("./log/summary.json", JSON.stringify({ numDocuments: documentCount, numUpdated, numProcessed, numFailed }, null, 2));
}

main()
    .catch(err => {
        console.error(`Failed with error:`);
        console.error(err);
        process.exit(1);
    });
