import path from 'path';
import fs from 'fs';
import AdmZip from "adm-zip";
import os from 'os';
import { createServer } from 'rest-api';
import { createPrivateKey } from "node:crypto";
import { StoragePrefixWrapper, createStorage, IStorageOptions, loadPrivateKey } from "storage";
import { registerTerminationCallback } from "node-utils";

import pfe from  "../pfe.zip" with { type: "file" } ;

//
// Starts the Photosphere ui.
//
export async function uiCommand(): Promise<void> {
    //
    // Extract frontend code if doesn't exist.
    //
    const frontendPath = path.join(os.tmpdir(), "photosphere/frontend/v1");
    if (!fs.existsSync(frontendPath)) {
        fs.mkdirSync(frontendPath, { recursive: true });

        const zip = new AdmZip(fs.readFileSync(pfe));
        zip.extractAllTo(frontendPath, true); //TODO: Could also just stream the contents without extracing it.

        console.log(`Extracted frontend to ${frontendPath}.`);
    }
    else {
        console.log(`Frontend already exists at ${frontendPath}.`);
    }

    console.log(`Serving frontend from ${frontendPath}.`);

    //
    // Start the Photosphere REST API.
    //
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

    //todo: Need to write in Google API key from somewhere.

    const { app, close } = await createServer(() => new Date(Date.now()), assetStorageWrapper, databaseStorageWrapper, {
        appMode: "readwrite", 
        authType: "no-auth",
        frontendStaticPath: path.join(frontendPath, "dist"),
    });

    registerTerminationCallback(async () => {
        // Shuts down the server gracefully on termination signals.
        await close();
    });

    app.listen(3000, () => { //TODO: Pick a random port.
       console.log("Photosphere editor started at http://localhost:3000");
    });
}