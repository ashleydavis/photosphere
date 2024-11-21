import { MongoClient } from "mongodb";
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

    let numProcessed = 0;
    let queryOffset = 0;
    const querySize = 100;
    const batchSize = 10;

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

                //
                // If it has the field exif, change it to metadata update the database document.
                //
                if (document.properties.exif) {
                    if (document.properties.metadata) {
                        throw new Error(`Document ${document._id} has exif and metadata!`);
                    }

                    const metadata = document.properties.exif;
                    console.log(JSON.stringify(metadata, null, 2));

                    await metadataCollection.updateOne({ _id: document._id }, {
                        $set: {
                            "properties.metadata": metadata,                            
                        },
                        $unset: {
                            "properties.exif": "",
                        },
                    });

                    console.log(`Updated document ${document._id}.`);
                }

                numProcessed += 1;
            }));
        }

        console.log(`Processed ${numProcessed} of ${documentCount} documents.`);
    }

    await client.close();

    console.log(`-- Summary --`);
    console.log(`Total documents ${documentCount}.`);
    console.log(`Processed: ${numProcessed}.`);

    await fs.ensureDir("./log");
    await fs.writeFile("./log/summary.json", JSON.stringify({ numDocuments: documentCount, numProcessed }, null, 2));
}

main()
    .catch(err => {
        console.error(`Failed with error:`);
        console.error(err);
        process.exit(1);
    });
