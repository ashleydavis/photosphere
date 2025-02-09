import { MongoClient } from "mongodb";
import { CloudStorage, deleteAssetWithRetry, getAssetInfoWithRetry, readAssetWithRetry, writeAssetWithRetry } from "storage";
const _ = require("lodash");
const minimist = require("minimist");
const fs = require("fs-extra");

import dayjs from "dayjs";
import customParseFormat from "dayjs/plugin/customParseFormat";
dayjs.extend(customParseFormat);

async function main() {
    const argv = minimist(process.argv.slice(2));

    const DB_CONNECTION_STRING = process.env.DB_CONNECTION_STRING;
    if (DB_CONNECTION_STRING === undefined) {
        throw new Error(`Set environment variable DB_CONNECTION_STRING.`);
    }

    const DB_NAME = process.env.DB_NAME;
    if (DB_NAME === undefined) {
        throw new Error(`Set environment variable DB_NAME.`);
    }

    const bucket = process.env.AWS_BUCKET as string;
    if (bucket === undefined) {
        throw new Error(`Set the AWS bucket through the environment variable AWS_BUCKET.`);
    }

    const storage = new CloudStorage(bucket);

    const client = new MongoClient(DB_CONNECTION_STRING);
    await client.connect();

    const db = client.db(DB_NAME);

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
    const querySize = 1_000;
    const batchSize = 100;

    function estimateJSONSize(jsonObj: any): number {
        // Convert the JSON object to a string
        const jsonString = JSON.stringify(jsonObj);

        // Encode the string in UTF-8 and calculate the byte length
        const sizeInBytes = new TextEncoder().encode(jsonString).length;

        return sizeInBytes;
    }

    let totalSize = 0;

    while (true) {
        const documents = await metadataCollection.find(query)
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

                try {
                    await metadataCollection.updateOne(
                        { _id: document._id }, 
                        { $set: { 
                            contentType: document.assetContentType 
                        }, 
                        $unset: { 
                            assetContentType: "", 
                            thumbContentType: "", 
                            displayContentType: "",
                            sortDate: "",                        } 
                        },
                    );

                    numUpdated += 1;
                }
                catch (err) {
                    console.error(`Failed for asset ${document._id}.`);
                    console.error(err);

                    numFailed += 1;
                }

                numProcessed += 1;

                totalSize += estimateJSONSize(document);
            }));

            console.log(`Processed ${numProcessed} of ${documentCount} documents.`);
        }
    }

    await client.close();

    console.log(`-- Summary --`);
    console.log(`Total documents ${documentCount}.`);
    console.log(`Updated: ${numUpdated}.`);
    console.log(`Processed: ${numProcessed}.`);

    console.log(`Total size: ${totalSize} bytes.`);

    const averageSize = totalSize / documentCount;
    console.log(`Average size: ${averageSize} bytes.`);

    await fs.ensureDir("./log");
    await fs.writeFile("./log/summary.json", JSON.stringify({ numDocuments: documentCount, numUpdated, numProcessed, numFailed, totalSize, averageSize }, null, 2));
}

main()
    .catch(err => {
        console.error(`Failed with error:`);
        console.error(err);
        process.exit(1);
    });
