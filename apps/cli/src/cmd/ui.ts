import path from 'path';
import fs from 'fs';
import AdmZip from "adm-zip";
import os from 'os';
import { createServer, SingleMediaFileDatabaseProvider } from 'rest-api';
import { createStorage, loadEncryptionKeys, pathJoin } from "storage";
import { registerTerminationCallback } from "node-utils";
import open from "open";
import { log } from "utils";
import pc from "picocolors";

// @ts-ignore
import pfe from  "../../pfe.zip" with { type: "file" } ;

export interface IUiCommandOptions {
    //
    // Set the path to the database metadata.
    //
    meta: string;

    //
    // Sets the path to private key file for encryption.
    //
    key: string;

    //
    // When true, the ui will not open in the browser.
    //
    noOpen: boolean;
}

//
// Command that starts the Photosphere ui.
//
export async function uiCommand(dbDir: string, options: IUiCommandOptions): Promise<void> {
    //
    // Extract frontend code if doesn't exist.
    //
    const frontendPath = path.join(os.tmpdir(), "photosphere/frontend/v1");
    if (!fs.existsSync(frontendPath)) {
        fs.mkdirSync(frontendPath, { recursive: true });

        const zip = new AdmZip(fs.readFileSync(pfe));
        zip.extractAllTo(frontendPath, true);

        console.log(`Extracted frontend to ${frontendPath}.`);
    }
    else {
        console.log(`Frontend already exists at ${frontendPath}.`);
    }

    console.log(`Serving frontend from ${frontendPath}.`);

    const { options: storageOptions } = await loadEncryptionKeys(options.key, false, "source");

    const { storage: assetStorage } = createStorage(dbDir, storageOptions);
    const { storage: metadataStorage } = createStorage(options.meta || pathJoin(dbDir, '.db'));
    const mediaFileDatabaseProvider = new SingleMediaFileDatabaseProvider(assetStorage, metadataStorage, "local", "local", process.env.GOOGLE_API_KEY);

    //
    // Start the Photosphere REST API.
    //
    const { app, close } = await createServer(() => new Date(Date.now()), mediaFileDatabaseProvider, undefined, {
        appMode: "readwrite", 
        authType: "no-auth",
        frontendStaticPath: path.join(frontendPath, "dist"),
        googleApiKey: process.env.GOOGLE_API_KEY,
    });

    registerTerminationCallback(async () => {
        // Shuts down the server gracefully on termination signals.
        await close();
    });

    app.listen(3000, () => {
        log.info(`Photosphere UI running on ${pc.green("http://localhost:3000")}`);
        log.info(pc.cyan("Press Ctrl+C in this terminal to stop the server."));

        if (!options.noOpen) {
            open("http://localhost:3000").catch((err) => {
                console.error("Failed to open browser:", err);
            });
        }
    });
}