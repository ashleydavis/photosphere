import { CloudStorage, FileStorage, IStorage } from "storage";
import { MongoClient } from "mongodb";
const _ = require("lodash");
const minimist = require("minimist");
const fs = require("fs-extra");

//
// Computes a hash for a file or blob of data.
// 
// https://developer.mozilla.org/en-US/docs/Web/API/SubtleCrypto/digest
// https://github.com/jsdom/jsdom/issues/1612#issuecomment-663210638
// https://www.npmjs.com/package/@peculiar/webcrypto
// https://github.com/PeculiarVentures/webcrypto-docs/blob/master/README.md
//
async function computeHash(data: Buffer): Promise<string> {
    const hashBuffer = await crypto.subtle.digest('SHA-256', data);
    const hashArray = Array.from(new Uint8Array(hashBuffer));
    const hashHex = hashArray.map((b) => b.toString(16).padStart(2, '0')).join('');
    return hashHex;
}

//
// Downloads an assert to the destination storage.
//
async function downloadAsset(sourceStorage: IStorage, destStorage: IStorage, metadata: any, assetType: string): Promise<void> {
    const fileInfo = await sourceStorage.info(`collections/${metadata.setId}/${assetType}`, metadata._id);
    if (!fileInfo) {
        throw new Error(`Document ${metadata._id} does not have file info:\r\n${JSON.stringify(metadata)}`);
    }
    
    const fileData = await sourceStorage.read(`collections/${metadata.setId}/${assetType}`, metadata._id);
    if (!fileData) {
        throw new Error(`Document ${metadata._id} does not have file data.`);
    }

    await destStorage.writeStream(`collections/${metadata.setId}/${assetType}`, metadata._id, fileInfo.contentType, 
        sourceStorage.readStream(`collections/${metadata.setId}/${assetType}`, metadata._id)
    );

    // console.log(`Wrote asset for ${assetType}/${metadata._id}.`);
}

async function main() {
    const argv = minimist(process.argv.slice(2));

    const DB_CONNECTION_STRING = process.env.DB_CONNECTION_STRING;
    if (DB_CONNECTION_STRING === undefined) {
        throw new Error(`Set environment variable DB_CONNECTION_STRING.`);
    }

    const client = new MongoClient(DB_CONNECTION_STRING);
    await client.connect();

    const db = client.db("photosphere");

    const LOCAL_STORAGE_DIR = process.env.LOCAL_STORAGE_DIR || "backup";

    const source = argv.source || "s3";
    const dest = argv.dest || "local";
    if (source !== "s3" && source !== "local") {
        throw new Error(`Invalid source: ${source}`);
    }
    if (dest !== "s3" && dest !== "local") {
        throw new Error(`Invalid destination: ${dest}`);
    }
    if (source === dest) {
        throw new Error(`Source and destination cannot be the same.`);
    }

    const sourceStorage = source == "s3" ? new CloudStorage() : new FileStorage(LOCAL_STORAGE_DIR);
    const destStorage = dest == "s3" ? new CloudStorage() : new FileStorage(LOCAL_STORAGE_DIR);

    console.log(`Source storage: ${source}`);
    console.log(`Destination storage: ${dest}`);

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

    let numMatching = 0;
    let numNotMatching = 0;
    let numDownloaded = 0;
    let numAlreadyDownloaded = 0;
    let queryOffset = 0;
    const querySize = 100;
    const batchSize = 100;

    while (true) {
        const documents = await metadataCollection.find(query)
            .skip(queryOffset)
            .limit(querySize)
            .toArray();

        if (documents.length === 0) {
            console.log(`No more documents to download.`);
            break;
        }

        queryOffset += documents.length;

        for (const batch of _.chunk(documents, batchSize)) {
            await Promise.all(batch.map(async (document: any) => {
                const isAlreadyDownloaded = await destStorage.exists(`collections/${document.setId}/metadata`, document._id);
                if (isAlreadyDownloaded) {
                    numAlreadyDownloaded += 1;
                    console.log(`Document ${document._id} already downloaded.`);
                }
                else {
                    console.log(`Downloading ${document._id}`);
        
                    if (!document.setId) {
                        throw new Error(`Document ${document._id} does not have a set ID.`);
                    }
        
                    if (!document.hash) {
                        throw new Error(`Document ${document._id} does not have a hash.`);
                    }
        
                    await downloadAsset(sourceStorage, destStorage, document, "asset");
                    if (document.contentType.startsWith("image")) {
                        await downloadAsset(sourceStorage, destStorage, document, "display");
                    }
                    await downloadAsset(sourceStorage, destStorage, document, "thumb");
                }

                //
                // Check the hash of the downloaded assets.
                //
                const fileData = await destStorage.read(`collections/${document.setId}/asset`, document._id);
                if (!fileData) {
                    throw new Error(`Document ${document._id} does not have data at ${dest}.`);
                }

                const hash = await computeHash(fileData);
                if (hash === document.hash) {
                    numMatching++;
                    // console.log(`Document ${document._id} has matching hash.`);            
                }
                else {
                    numNotMatching++;
                    console.error(`Document ${document._id} has non-matching hash.`);
                }

                if (!isAlreadyDownloaded) {
                    //
                    // The final thing is to download the metadata if not already downloaded.
                    // If anything else fails (including checking the hash) the metadata will not be downloaded.
                    //
                    await destStorage.write(`collections/${document.setId}/metadata`, document._id, "application/json", Buffer.from(JSON.stringify(document)));

                    console.log(`Downloaded asset ${document._id} to ${dest}.`);
                    numDownloaded += 1;
                }
            }));
        }

        console.log(`Downloaded ${documents.length} of ${documentCount} documents.`);
    }

    await client.close();

    console.log(`-- Summary --`);
    console.log(`Found ${numMatching} documents with matching hash.`);
    console.log(`Found ${numNotMatching} documents with non-matching hash.`);
    console.log(`Total documents ${documentCount}.`);
    console.log(`Already downloaded: ${numAlreadyDownloaded}.`);
    console.log(`Downloaded: ${numDownloaded}.`);

    await fs.ensureDir("./log");
    await fs.writeFile("./log/summary.json", JSON.stringify({ numMatching, numNotMatching, numDocuments: documentCount, numAlreadyDownloaded, numDownloaded }, null, 2));
}

main()
    .catch(err => {
        console.error(`Failed with error:`);
        console.error(err);
        process.exit(1);
    });
