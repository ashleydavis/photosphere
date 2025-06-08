import fs from 'fs/promises';
import { createServer, SingleMediaFileDatabaseProvider } from 'rest-api';
import { createStorage, loadEncryptionKeys, pathJoin } from "storage";
import { exit, registerTerminationCallback } from "node-utils";
import open from "open";
import { log } from "utils";
import pc from "picocolors";
import { createZipStaticMiddleware } from '../lib/zip-static-middleware';
import { configureS3IfNeeded } from '../lib/s3-config';
import { ensureMediaProcessingTools } from '../lib/ensure-tools';

// @ts-ignore
import pfe from  "../../pfe.zip" with { type: "file" } ;

export interface IUiCommandOptions {
    //
    // Set the path to the database metadata.
    //
    meta?: string;

    //
    // Sets the path to private key file for encryption.
    //
    key?: string;

    //
    // When true, the ui will not open in the browser.
    //
    noOpen?: boolean;

    //
    // Non-interactive mode - use defaults and command line arguments.
    //
    yes?: boolean;
}

//
// Command that starts the Photosphere ui.
//
export async function uiCommand(dbDir: string, options: IUiCommandOptions): Promise<void> {
    // Ensure media processing tools are available
    await ensureMediaProcessingTools(options.yes || false);

    //
    // Configure S3 if the path requires it
    //
    if (!await configureS3IfNeeded(dbDir)) {
        await exit(1);
    }
    
    const metaPath = options.meta || pathJoin(dbDir, '.db');
    if (!await configureS3IfNeeded(metaPath)) {
        await exit(1);
    }
    
    //
    // Load the embedded frontend zip file into memory
    //
    const zipBuffer = await fs.readFile(pfe);
    
    //
    // Create middleware to serve files from the in-memory zip
    // The frontend files are in the 'dist' directory within the zip
    //
    const staticMiddleware = createZipStaticMiddleware(zipBuffer, 'dist');

    const { options: storageOptions } = await loadEncryptionKeys(options.key, false, "source");

    const { storage: assetStorage } = createStorage(dbDir, storageOptions);
    const { storage: metadataStorage } = createStorage(metaPath);
    const mediaFileDatabaseProvider = new SingleMediaFileDatabaseProvider(assetStorage, metadataStorage, "local", "local", process.env.GOOGLE_API_KEY);

    //
    // Start the Photosphere REST API.
    //
    const { app, close } = await createServer(() => new Date(Date.now()), mediaFileDatabaseProvider, undefined, {
        appMode: "readwrite", 
        authType: "no-auth",
        staticMiddleware,
        googleApiKey: process.env.GOOGLE_API_KEY,
    });

    registerTerminationCallback(async () => {
        // Shuts down the server gracefully on termination signals.
        await close();

        await mediaFileDatabaseProvider.close();
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