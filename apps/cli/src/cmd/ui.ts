import fs from 'fs/promises';
import { createServer, SingleMediaFileDatabaseProvider } from 'rest-api';
import { createStorage, loadEncryptionKeys, pathJoin } from "storage";
import { exit, registerTerminationCallback } from "node-utils";
import open from "open";
import { log } from "utils";
import pc from "picocolors";
import { createZipStaticMiddleware } from '../lib/zip-static-middleware';
import { configureIfNeeded, getS3Config } from '../lib/config';
import { ensureMediaProcessingTools } from '../lib/ensure-tools';
import { resolveKeyPath } from '../lib/init-cmd';
import { createServer as createHttpServer } from 'http';
import { AddressInfo } from 'net';

// @ts-ignore
import pfe from  "../../pfe.zip" with { type: "file" } ;
import { getDirectoryForCommand } from '../lib/directory-picker';

//
// Find an available port by creating a temporary server on port 0
//
async function findAvailablePort(): Promise<number> {
    return new Promise((resolve, reject) => {
        const server = createHttpServer();
        server.listen(0, () => {
            const addressInfo = server.address() as AddressInfo;
            const port = addressInfo.port;
            server.close(() => {
                resolve(port);
            });
        });
        server.on('error', reject);
    });
}

export interface IUiCommandOptions {
    //
    // Database directory path.
    //
    db: string;

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
    // Set the current working directory for directory selection prompts.
    //
    cwd?: string;
}

//
// Command that starts the Photosphere ui.
//
export async function uiCommand(options: IUiCommandOptions): Promise<void> {

    // Ensure media processing tools are available
    await ensureMediaProcessingTools(false);

    if (options.db === undefined) {
        options.db = await getDirectoryForCommand("existing", false, options.cwd || process.cwd());
    }

    //
    // Configure S3 if the path requires it
    //
    if (options.db.startsWith("s3:")) {
        await configureIfNeeded(['s3'], false);
    }
    
    const metaPath = options.meta || pathJoin(options.db, '.db');
    if (metaPath.startsWith("s3:")) {
        await configureIfNeeded(['s3'], false);
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

    const resolvedKeyPath = await resolveKeyPath(options.key);
    const { options: storageOptions } = await loadEncryptionKeys(resolvedKeyPath, false);

    const s3Config = await getS3Config();
    const { storage: assetStorage } = createStorage(options.db, s3Config, storageOptions);
    const { storage: metadataStorage } = createStorage(metaPath, s3Config);
    const mediaFileDatabaseProvider = new SingleMediaFileDatabaseProvider(assetStorage, metadataStorage, "local", "local", process.env.GOOGLE_API_KEY);

    //
    // Start the Photosphere REST API.
    //
    const { app } = await createServer(() => new Date(Date.now()), mediaFileDatabaseProvider, undefined, {
        appMode: "readwrite", 
        authType: "no-auth",
        staticMiddleware,
        googleApiKey: process.env.GOOGLE_API_KEY,
    });

    registerTerminationCallback(async () => {
        // Shuts down the server gracefully on termination signals.
        await close();
    });

    //
    // Find an available port and start the server
    //
    const port = await findAvailablePort();
    const url = `http://localhost:${port}`;
    
    app.listen(port, () => {
        log.info(`Photosphere UI running on ${pc.green(url)}`);
        log.info(pc.cyan("Press Ctrl+C in this terminal to stop the server."));

        if (!options.noOpen) {
            open(url).catch((err) => {
                console.error("Failed to open browser:", err);
            });
        }
    });
}