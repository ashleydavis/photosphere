import { MongoClient } from "mongodb";
import { resizeImage, transformImage } from "node-utils";
import { CloudStorage, deleteAssetWithRetry, getAssetInfoWithRetry, readAssetWithRetry, writeAssetWithRetry } from "storage";
import { IImageTransformation } from "utils";
const _ = require("lodash");
const minimist = require("minimist");
const fs = require("fs-extra");


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
                    if (document) {

                        const thumbInfo = await getAssetInfoWithRetry(storage, document._id, document.setId, "thumb-transformed");
                        if (thumbInfo) {
                            const thumb = await readAssetWithRetry(storage, document._id, document.setId, "thumb-transformed");
                            if (thumb) {
                                await writeAssetWithRetry(storage, document._id, document.setId, "thumb", thumbInfo.contentType, thumb);

                                await deleteAssetWithRetry(storage, document._id, document.setId, "thumb-transformed");

                                //
                                // Remove transformed field.
                                //
                                await metadataCollection.updateOne({ _id: document._id }, {
                                    $unset: {
                                        transformed: "",
                                    },
                                });
                            }
                        }

                        numUpdated += 1;
                    }
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
