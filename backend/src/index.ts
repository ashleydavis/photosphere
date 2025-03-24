import { MongoClient } from "mongodb";
import { createServer } from "./server";
import { StoragePrefixWrapper, IStorage, createStorage } from "storage";

async function main() {

    const PORT = process.env.PORT;
    if (!PORT) {
        throw new Error(`Set environment variable PORT.`);
    }

    const DB_CONNECTION_STRING = process.env.DB_CONNECTION_STRING;
    if (DB_CONNECTION_STRING === undefined) {
        throw new Error(`Set environment variable DB_CONNECTION_STRING.`);
    }

    const DB_NAME = process.env.DB_NAME;
    if (DB_NAME === undefined) {
        throw new Error(`Set environment variable DB_NAME.`);
    }

    const client = new MongoClient(DB_CONNECTION_STRING);
    await client.connect();

    const db = client.db(DB_NAME);
    
    console.log(`Running in mode: ${process.env.NODE_ENV} on port ${PORT}.`);

    const storageConnection = process.env.STORAGE_CONNECTION;
    if (!storageConnection) {
        throw new Error(`Set the storage type and root path through the environment variable STORAGE_CONNECTION.`);
    }
    
    const { storage, normalizedPath } = createStorage(storageConnection);   
    const storageWrapper = new StoragePrefixWrapper(storage, normalizedPath);

    const app = await createServer(() => new Date(Date.now()), db, storageWrapper);
    app.listen(PORT, () => {
        console.log(`Photosphere listening on port ${PORT}`);
    });
}

main()
    .catch(err => {
        console.error(`Something went wrong.`);
        console.error(err);
        process.exit(1);
    });

