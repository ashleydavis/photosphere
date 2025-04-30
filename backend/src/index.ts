import { createPrivateKey } from "node:crypto";
import { createServer } from "rest-api";
import { StoragePrefixWrapper, createStorage, IStorageOptions, loadPrivateKey } from "storage";
import { registerTerminationCallback } from "./lib/termination";

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

    let storageOptions: IStorageOptions | undefined = undefined;

    if (process.env.ASSET_STORAGE_PRIVATE_KEY) {
        const privateKey = process.env.ASSET_STORAGE_PRIVATE_KEY;

        storageOptions = {
            privateKey: createPrivateKey(privateKey),
        };
    }
    else if (process.env.ASSET_STORAGE_PRIVATE_KEY_FILE) {
        const privateKeyFile = process.env.ASSET_STORAGE_PRIVATE_KEY_FILE;
        const privateKey = await loadPrivateKey(privateKeyFile);
        if (!privateKey) {
            throw new Error(`Private key file ${privateKeyFile} not found.`);
        }
        storageOptions = {
            privateKey: privateKey,
        };
    }

    const { storage: assetStorage, normalizedPath: assetPath } = createStorage(assetStorageConnection, storageOptions);
    const assetStorageWrapper = new StoragePrefixWrapper(assetStorage, assetPath);

    const { storage: dbStorage, normalizedPath: dbPath } = createStorage(databaseStorageConnection);
    const databaseStorageWrapper = new StoragePrefixWrapper(dbStorage, dbPath);

    const { app, close } = await createServer(() => new Date(Date.now()), assetStorageWrapper, databaseStorageWrapper);
    app.listen(PORT, () => {
        console.log(`Photosphere listening on port ${PORT}`);
    });

    registerTerminationCallback(async () => {
        // Shuts down the server gracefully on termination signals.
        await close();
    });    
}

main()
    .catch(err => {
        console.error(`Something went wrong.`);
        console.error(err);
        process.exit(1);
    });

