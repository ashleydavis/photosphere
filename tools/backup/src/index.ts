import dayjs from "dayjs";
import { CloudStorage, FileStorage } from "storage";
import { MongoClient } from "mongodb";
const _ = require("lodash");
const minimist = require("minimist");

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
// Downloads an assert to local storage.
//
async function downloadAsset(cloudStorage: CloudStorage, localStorage: FileStorage, metadata: any, assetType: string): Promise<void> {
    const fileInfo = await cloudStorage.info(`collections/${metadata.setId}/${assetType}`, metadata._id);
    if (!fileInfo) {
        throw new Error(`Document ${metadata._id} does not have file info:\r\n${JSON.stringify(metadata)}`);
    }
    
    const fileData = await cloudStorage.read(`collections/${metadata.setId}/${assetType}`, metadata._id);
    if (!fileData) {
        throw new Error(`Document ${metadata._id} does not have file data.`);
    }

    await localStorage.writeStream(`collections/${metadata.setId}/${assetType}`, metadata._id, fileInfo.contentType, 
        cloudStorage.readStream(`collections/${metadata.setId}/${assetType}`, metadata._id)
    );

    // console.log(`Wrote asset for ${assetType}/${metadata._id} to local storage.`);
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

    const DB_BACKUP_TARGET_DIR = process.env.DB_BACKUP_TARGET_DIR || "backup";
    
    const cloudStorage = new CloudStorage();
    const localStorage = new FileStorage(DB_BACKUP_TARGET_DIR);

    const query: any = {};

    if (argv.asset) {
        query._id = argv.asset;
    }

    const metadataCollection = db.collection<any>("metadata");
    const documents = await metadataCollection.find(query).toArray();
    console.log(`Found ${documents.length} documents in the collection.`);

    let numMatching = 0;
    let numNotMatching = 0;
    let numDocuments = 0;
    let numDownloaded = 0;
    let numAlreadyDownloaded = 0;
    const batchSize = 100;

    for (const batch of _.chunk(documents, batchSize)) {
        await Promise.all(batch.map(async (document: any) => {
            if (await localStorage.exists(`collections/${document.setId}/metadata`, document._id)) {
                numAlreadyDownloaded += 1;
                // console.log(`Document ${document._id} already downloaded.`);
                return;
            }

            // console.log(document._id);

            if (!document.setId) {
                throw new Error(`Document ${document._id} does not have a set ID.`);
            }

            if (!document.hash) {
                throw new Error(`Document ${document._id} does not have a hash.`);
            }

            await downloadAsset(cloudStorage, localStorage, document, "asset");
            if (document.contentType.startsWith("image")) {
                await downloadAsset(cloudStorage, localStorage, document, "display");
            }
            await downloadAsset(cloudStorage, localStorage, document, "thumb");

            //
            // Check the hash of the downloaded assets.
            //
            const fileData = await localStorage.read(`collections/${document.setId}/asset`, document._id);
            if (!fileData) {
                throw new Error(`Document ${document._id} does not have local file data.`);
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

            await localStorage.write(`collections/${document.setId}/metadata`, document._id, "application/json", Buffer.from(JSON.stringify(document)));

            // console.log(`Downloaded asset ${document._id} to local storage.`);

            numDownloaded += 1;
        }));

        numDocuments += batchSize;
            
        if ((numDocuments % 1000) === 0) {
            console.log(`Downloaded ${numDocuments} of ${documents.length} documents.`);
        }
    }

    await client.close();

    console.log(`Found ${numMatching} documents with matching hash.`);
    console.log(`Found ${numNotMatching} documents with non-matching hash.`);
    console.log(`Total documents ${documents.length}.`);
    console.log(`Already downloaded: ${numAlreadyDownloaded}.`);
    console.log(`Downloaded: ${numDownloaded}.`);
}

main()
    .catch(err => {
        console.error(`Failed with error:`);
        console.error(err);
        process.exit(1);
    });
