import { MongoClient } from "mongodb";
import { isArray } from "util";
import { chooseBestResult, convertExifCoordinates, getFirstResultOfType, isLocationInRange, retry, reverseGeocode } from "utils";
const _ = require("lodash");
const minimist = require("minimist");
const fs = require("fs-extra");

async function main() {
    const argv = minimist(process.argv.slice(2));

    const DB_CONNECTION_STRING = process.env.DB_CONNECTION_STRING;
    if (DB_CONNECTION_STRING === undefined) {
        throw new Error(`Set environment variable DB_CONNECTION_STRING.`);
    }

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
    let queryOffset = 0;
    const querySize = 10_000;
    const batchSize = 1_000;

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

                if (document.properties.reverseGeocoding !== undefined) {

                    let res;
                    if (isArray(document.properties.reverseGeocoding)) {
                        res = document.properties.reverseGeocoding;
                    }
                    else {
                        res = document.properties.reverseGeocoding.fullResult;
                    }

                    const result = chooseBestResult(res);

                    await metadataCollection.updateOne({ _id: document._id }, {
                        $set: {
                            location: result.location,
                            "properties.reverseGeocoding": {
                                type: result.type,
                                fullResult: res,
                            },
                        },
                    });

                    // console.log(`Updated document ${document._id}.`);

                    numUpdated += 1;
                }

                numProcessed += 1;
            }));
        }

        console.log(`Processed ${numProcessed} of ${documentCount} documents.`);
    }

    await client.close();

    console.log(`-- Summary --`);
    console.log(`Total documents ${documentCount}.`);
    console.log(`Updated: ${numUpdated}.`);
    console.log(`Processed: ${numProcessed}.`);

    await fs.ensureDir("./log");
    await fs.writeFile("./log/summary.json", JSON.stringify({ numDocuments: documentCount, numUpdated, numProcessed }, null, 2));
}

main()
    .catch(err => {
        console.error(`Failed with error:`);
        console.error(err);
        process.exit(1);
    });
