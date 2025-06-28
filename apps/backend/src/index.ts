import { createPrivateKey } from "node:crypto";
import express from "express";
import { createServer, IAuth0Options, MultipleMediaFileDatabaseProvider, SingleMediaFileDatabaseProvider } from "rest-api";
import { createStorage, IStorageOptions, loadPrivateKey, pathJoin } from "storage";
import { exit, registerTerminationCallback } from "node-utils";

async function main() {

    //
    // Check if a --path argument was provided for single directory mode
    //
    const pathArgIndex = process.argv.indexOf('--path');
    const hasPathArg = pathArgIndex !== -1;
    const singleDirPath = hasPathArg && process.argv[pathArgIndex + 1] ? process.argv[pathArgIndex + 1] : undefined;
    
    if (hasPathArg && !singleDirPath) {
        console.error('Error: Gallery path required when using --path. Usage: bun run start --path /path/to/gallery');
        await exit(1);
    }
    
    const isSingleDirMode = !!singleDirPath;
    
    if (isSingleDirMode) {
        console.log(`Running in single directory mode with path: ${singleDirPath}`);
    }

    const PORT = process.env.PORT;
    if (!PORT) {
        throw new Error(`Set environment variable PORT.`);
    }

    let FRONTEND_STATIC_PATH = process.env.FRONTEND_STATIC_PATH;
    if (FRONTEND_STATIC_PATH) {
        console.log(`Serving frontend from ${FRONTEND_STATIC_PATH}.`);
    }

    console.log(`Running in mode: ${process.env.NODE_ENV} on port ${PORT}.`);

    let assetStorageConnection: string;
    let databaseStorageConnection: string;
    
    if (isSingleDirMode) {
        //
        // In single directory mode, use the provided path for assets
        // and a .db subdirectory for database storage
        //
        assetStorageConnection = `fs:${singleDirPath}`;
        databaseStorageConnection = `fs:${pathJoin(singleDirPath, '.db')}`;
    }
    else {
        //
        // Normal mode - use environment variables
        //
        assetStorageConnection = process.env.ASSET_STORAGE_CONNECTION!;
        if (!assetStorageConnection) {
            throw new Error(`Set the asset databases storage type and root path through the environment variable ASSET_STORAGE_CONNECTION.`);
        }

        databaseStorageConnection = process.env.DB_STORAGE_CONNECTION!;
        if (!databaseStorageConnection) {
            throw new Error(`Set the generate database storage type and root path through the environment variable DB_STORAGE_CONNECTION.`);
        }
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

    const { storage: assetStorage } = createStorage(assetStorageConnection, undefined, storageOptions);    
    const { storage: metadataStorage } = createStorage(isSingleDirMode ? databaseStorageConnection : assetStorageConnection);    
    const { storage: dbStorage } = createStorage(databaseStorageConnection);
    
    const mediaFileDatabaseProvider = isSingleDirMode 
        ? new SingleMediaFileDatabaseProvider(assetStorage, metadataStorage, "local", "local", process.env.GOOGLE_API_KEY)
        : new MultipleMediaFileDatabaseProvider(assetStorage, metadataStorage, process.env.GOOGLE_API_KEY);

    const APP_MODE = isSingleDirMode ? "readwrite" : process.env.APP_MODE;
    if (!APP_MODE) {
        throw new Error("Expected APP_MODE environment variable set to 'readonly' or 'readwrite'");
    }

    const AUTH_TYPE = isSingleDirMode ? "no-auth" : process.env.AUTH_TYPE;
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

        if (!process.env.AUTH0_REDIRECT_URL) {
            throw new Error("Expected AUTH0_REDIRECT_URL environment variable");
        }

        auth0Options = {
            audience: process.env.AUTH0_AUDIENCE,
            domain: process.env.AUTH0_DOMAIN,
            clientId: process.env.AUTH0_CLIENT_ID,
            redirectUrl: process.env.AUTH0_REDIRECT_URL,
        };
    }

    if (!process.env.GOOGLE_API_KEY) {
        console.warn("Google API key not set. Reverse geocoding will not work.");
    }

    const { app, close } = await createServer(() => new Date(Date.now()), mediaFileDatabaseProvider, dbStorage, {
        appMode: APP_MODE,
        authType: AUTH_TYPE,
        staticMiddleware: FRONTEND_STATIC_PATH ? express.static(FRONTEND_STATIC_PATH) : undefined,
        auth0: auth0Options,
        googleApiKey: process.env.GOOGLE_API_KEY,        
    });

    registerTerminationCallback(async () => {
        // Shuts down the server gracefully on termination signals.
        await close();

        await mediaFileDatabaseProvider.close();
    });    

    app.listen(PORT, () => {
        console.log(`Photosphere listening on port ${PORT}`);
    });
}

main()
    .catch(err => {
        console.error(`Something went wrong.`);
        console.error(err);
        exit(1);
    });

