import { MongoClient } from "mongodb";
import { BsonDatabase, CloudStorage, deleteAssetWithRetry, EncryptedStorage, FileStorage, getAssetInfoWithRetry, readAssetWithRetry, writeAssetWithRetry } from "storage";
import { sleep } from "utils";
const _ = require("lodash");
const minimist = require("minimist");
const fs = require("fs-extra");
const ColorThief = require("colorthief");
import crypto from "crypto";

import dayjs from "dayjs";
import customParseFormat from "dayjs/plugin/customParseFormat";
import { getImageResolution, resizeImage } from "node-utils";
import { IAsset } from "defs";
dayjs.extend(customParseFormat);

async function main() {
    const argv = minimist(process.argv.slice(2));

    const DB_CONNECTION_STRING = process.env.DB_CONNECTION_STRING;
    if (!DB_CONNECTION_STRING) {
        throw new Error(`Set environment variable DB_CONNECTION_STRING.`);
    }

    const DB_NAME = process.env.DB_NAME;
    if (!DB_NAME) {
        throw new Error(`Set environment variable DB_NAME.`);
    }

    const bucket = process.env.AWS_BUCKET as string;
    if (!bucket) {
        throw new Error(`Set the AWS bucket through the environment variable AWS_BUCKET.`);
    }

    // const storage = new CloudStorage(true);
    const storage = new FileStorage();
    
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

    const bsonDatabase = new BsonDatabase({ //todo: need a separate database for each set.
        storage,
        // directory: "storage-test-next:/test-12", todo
        directory: "./storage-test",  //fio:
    });

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
    let minDocumentSize = Number.MAX_SAFE_INTEGER;
    let maxDocumentSize = 0;
    const sizePerSet = new Map<string, number>();

    // let allJsonDocs: any[] = [];
    // let allBinaryDocs: any[] = [];

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
            await Promise.all(batch.map(async (document: IAsset) => {

                try {

                    if (document.encrypted) {
                        console.log(`Asset ${document._id} is already encrypted.`);
                        return;
                    }
                    else {
                        //todo: encrypt the assets.

                        await metadataCollection.updateOne(
                            { _id: document._id },
                            {
                                $set: {
                                    encrypted: true,
                                },
                            }
                        );

                        numUpdated += 1;
                    }
                }
                catch (err) {
                    console.error(`Failed for asset ${document._id}.`);
                    console.error(err);

                    numFailed += 1;
                }

                numProcessed += 1;


                const docSize = estimateJSONSize(document);

                totalSize += docSize;
                minDocumentSize = Math.min(minDocumentSize, docSize);
                maxDocumentSize = Math.max(maxDocumentSize, docSize);

                //
                // Update size for each set.
                //
                sizePerSet.set(document.setId, (sizePerSet.get(document.setId) || 0) + docSize);

            }));

            console.log(`Processed ${numProcessed} of ${documentCount} documents.`);
        }
    }

    await bsonDatabase.shutdown();

    await client.close();

    console.log(`-- Summary --`);
    console.log(`Total documents ${documentCount}.`);
    console.log(`Updated: ${numUpdated}.`);
    console.log(`Processed: ${numProcessed}.`);

    console.log(`Total size: ${totalSize} bytes.`);

    const averageSize = totalSize / documentCount;
    console.log(`Average size: ${averageSize} bytes.`);

    console.log(`Min document size: ${minDocumentSize} bytes.`);
    console.log(`Max document size: ${maxDocumentSize} bytes.`);

    await fs.ensureDir("./log");
    await fs.writeFile("./log/summary.json", JSON.stringify({ numDocuments: documentCount, numUpdated, numProcessed, numFailed, totalSize, averageSize }, null, 2));

    console.log(sizePerSet);

    // Write the JSON documents to a single file.
    // await fs.ensureDir("./output");
    // await fs.writeFile("./output/all.json", JSON.stringify(allJsonDocs));

    // // Write the BSON documents to a single file.
    // await fs.ensureDir("./output");
    // await fs.writeFile("./output/all.bson", BSON.serialize(allJsonDocs));

    // // Write the binary BSON documents to a single file.
    // await fs.ensureDir("./output");
    // await fs.writeFile("./output/all-binary.bson", BSON.serialize(allBinaryDocs));
}

main()
    .catch(err => {
        console.error(`Failed with error:`);
        console.error(err);
        process.exit(1);
    });

// (async () => {

//     const publicKey = crypto.createPublicKey(fs.readFileSync("./keys/public.pem"));
//     const privateKey = crypto.createPrivateKey(fs.readFileSync("./keys/private.pem"));

//     const fileStorage = new FileStorage("./test");
//     const encryptedStorage = new EncryptedStorage(fileStorage, publicKey, privateKey);

//     const readStream = fs.createReadStream("./src/index.ts");
//     await encryptedStorage.writeStream("test", "index.ts.enc", "text/plain", readStream);

//     const decryptedStream = await encryptedStorage.readStream("test", "index.ts.enc");
//     const writeStream = fs.createWriteStream("./src/index.ts.dec");
//     decryptedStream.pipe(writeStream);

//     await sleep(1000);

//     const file = fs.readFileSync("./src/index.ts");
//     const decryptedData = fs.readFileSync("./src/index.ts.dec");

//     // // Write the file to storage.
//     // await encryptedStorage.write("test", "index.ts.enc", "text/plain", file);

//     // // Read the file from storage.
//     // const decryptedData = await encryptedStorage.read("test", "index.ts.enc");

//     if (!file.equals(decryptedData)) {
//         throw new Error(`Decrypted data does not match the original data.`);
//     }
//     else {
//         console.log(`Decrypted data matches the original data.`);
//     }

// })();



