import { createPrivateKey } from "node:crypto";
import { createServer, IAuth0Options } from "rest-api";
import { StoragePrefixWrapper, createStorage, IStorageOptions, loadPrivateKey } from "storage";
import { registerTerminationCallback } from "node-utils";

async function main() {

    const PORT = process.env.PORT;
    if (!PORT) {
        throw new Error(`Set environment variable PORT.`);
    }

    let FRONTEND_STATIC_PATH = process.env.FRONTEND_STATIC_PATH;
    if (FRONTEND_STATIC_PATH) {
        console.log(`Serving frontend from ${FRONTEND_STATIC_PATH}.`);
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

    const APP_MODE = process.env.APP_MODE;
    if (!APP_MODE) {
        throw new Error("Expected APP_MODE environment variable set to 'readonly' or 'readwrite'");
    }

    const AUTH_TYPE = process.env.AUTH_TYPE;
    if (!AUTH_TYPE) {
        throw new Error("Expected AUTH_TYPE environment variable set to 'auth0' or 'no-auth'");
    }

    let auth0Options: IAuth0Options | undefined = undefined;

    if (AUTH_TYPE === "auth0") {
        if (!process.env.AUTH0_AUDIENCE) {
            throw new Error("Expected AUTH0_AUDIENCE environment variable");
        }

        if (!process.env.AUTH0_DOMAIN) {
            throw new Error("Expected AUTH0_DOMAIN environment variable");
        }

        if (!process.env.AUTH0_CLIENT_ID) {
            throw new Error("Expected AUTH0_CLIENT_ID environment variable");
        }

        auth0Options = {
            audience: process.env.AUTH0_AUDIENCE,
            domain: process.env.AUTH0_DOMAIN,
            clientId: process.env.AUTH0_CLIENT_ID,
        };
    }

    if (!process.env.GOOGLE_API_KEY) {
        console.warn("Google API key not set. Reverse geocoding will not work.");
    }

    const { app, close } = await createServer(() => new Date(Date.now()), assetStorageWrapper, databaseStorageWrapper, {
        appMode: APP_MODE,
        authType: AUTH_TYPE,
        frontendStaticPath: FRONTEND_STATIC_PATH,
        auth0: auth0Options,
        googleApiKey: process.env.GOOGLE_API_KEY,
    });

    registerTerminationCallback(async () => {
        // Shuts down the server gracefully on termination signals.
        await close();
    });    

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

