import { createServer } from "./server";
import { StoragePrefixWrapper, IStorage, createStorage } from "storage";

async function main() {

    const PORT = process.env.PORT;
    if (!PORT) {
        throw new Error(`Set environment variable PORT.`);
    }

    console.log(`Running in mode: ${process.env.NODE_ENV} on port ${PORT}.`);

    const assetStorageConnection = process.env.ASSET_STORAGE_CONNECTION;
    if (!assetStorageConnection) {
        throw new Error(`Set the asset databases storage type and root path through the environment variable ASSET_STORAGE_CONNECTION.`);
    }

    const databaseStorageConnection = process.env.DB_STORAGE_CONNECTION;
    if (!databaseStorageConnection) {
        throw new Error(`Set the generate database storage type and root path through the environment variable DB_STORAGE_CONNECTION.`);
    }

    const { storage: assetStorage, normalizedPath: assetPath } = createStorage(assetStorageConnection);
    const assetStorageWrapper = new StoragePrefixWrapper(assetStorage, assetPath);

    const { storage: dbStorage, normalizedPath: dbPath } = createStorage(databaseStorageConnection);
    const databaseStorageWrapper = new StoragePrefixWrapper(dbStorage, dbPath);

    const app = await createServer(() => new Date(Date.now()), assetStorageWrapper, databaseStorageWrapper);
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

