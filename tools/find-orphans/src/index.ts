import { MongoClient } from "mongodb";
import { CloudStorage } from "storage";
import _ from "lodash";
const minimist = require("minimist");

import dayjs from "dayjs";
import customParseFormat from "dayjs/plugin/customParseFormat";
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
    // const documentCount = await metadataCollection.countDocuments(query);
    // console.log(`Found ${documentCount} documents in the collection.`);

    let numAssetsChecked = 0;
    let numOrphans = 0;
    let numOk = 0;

    //
    // List all assets in storage.
    //
    async function listAssets(storage: CloudStorage, dir: string): Promise<void> {
        let next: string | undefined = undefined;
        do {
            const result = await storage.list(dir, 1000, next);
            //
            // Checks the assets in batches.
            //
            for (const batch of _.chunk(result.fileNames, 100)) {
                await Promise.all(batch.map(async fileName => {
                    const asset = await metadataCollection.findOne({ _id: fileName });
                    if (!asset) {
                        await storage.delete(dir, fileName);
                        console.log(`Deleted orphaned asset: ${fileName}`);
                        numOrphans++;
                    }
                    else {
                        // console.log(`Found asset: ${fileName}`);
                        numOk++;
                    }
    
                    numAssetsChecked++;
                    if (numAssetsChecked % 100 === 0) {
                        console.log(`Checked ${numAssetsChecked} assets.`);
                    }
                }));

                // for (const fileName of result.fileNames) {
                //     const asset = await metadataCollection.findOne({ _id: fileName });
                //     if (!asset) {
                //         console.log(`Orphaned asset: ${fileName}`);
                //         numOrphans++;
                //     }
                //     else {
                //         // console.log(`Found asset: ${fileName}`);
                //     }
    
                //     numAssetsChecked++;
                //     if (numAssetsChecked % 100 === 0) {
                //         console.log(`Checked ${numAssetsChecked} assets.`);
                //     }
                // }
            }            

            next = result.next;
        } while (next);

        console.log(`Checked assets in ${dir}.`);
    }

    const sets = [
        "4defc344-213e-4d49-ae2f-061cfcc2d4bd",
        "7bcbae70-9a85-4aea-8ec6-cbb6105e1dd9",
        "9a939a76-bdbc-43c1-8bd2-ecc94301f014",
        "d5a75330-61ca-487d-b81b-0d2aeaa74c76",
    ];

    const assetTypes = [
        "asset",
        "display",
        "thumb",
    ];

    const promises = sets.flatMap(set => {
        return assetTypes.map(assetType => {
            return listAssets(storage, `collections/${set}/${assetType}`);
        });
    });
    await Promise.all(promises);

    // //
    // // Enumerate all assets in storage.
    // //
    // for (const set of sets) {
    //     console.log(`Checking set ${set}...`);
    //     for (const assetType of assetTypes) {
    //         console.log(`Checking asset type ${assetType}...`);
    //         await listAssets(storage, `collections/${set}/${assetType}`);
    //     }
    // }

    console.log(`Checked ${numAssetsChecked} assets.`);
    console.log(`Deleted ${numOrphans} orphans.`);
    console.log(`Found ${numOk} assets that were ok.`);
}

main()
    .catch(err => {
        console.error(`Failed with error:`);
        console.error(err);
        process.exit(1);
    });