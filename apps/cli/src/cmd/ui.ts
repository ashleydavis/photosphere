import fs from 'fs/promises';
import { createServer, SingleMediaFileDatabaseProvider } from 'rest-api';
import { createStorage, loadEncryptionKeys, pathJoin } from "storage";
import open from "open";
import { log, TimestampProvider } from "utils";
import pc from "picocolors";
import { createZipStaticMiddleware } from '../lib/zip-static-middleware';
import { configureIfNeeded, getS3Config } from '../lib/config';
import { ensureMediaProcessingTools } from '../lib/ensure-tools';
import { resolveKeyPath } from '../lib/init-cmd';
// @ts-ignore
import pfe from  "../../pfe.zip" with { type: "file" } ;
import { getDirectoryForCommand } from '../lib/directory-picker';
import { findAvailablePort } from 'node-utils';

export interface IUiCommandOptions {
    //
    // Database directory path.
    //
    db: string;

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
    
    const metaPath = pathJoin(options.db, '.db');
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
    const mediaFileDatabaseProvider = new SingleMediaFileDatabaseProvider(assetStorage, "local", "local", process.env.GOOGLE_API_KEY);

    //
    // Start the Photosphere REST API.
    //
    const { app } = await createServer(() => new Date(Date.now()), mediaFileDatabaseProvider, new TimestampProvider(), undefined, {
        appMode: "readwrite", 
        authType: "no-auth",
        staticMiddleware,
        googleApiKey: process.env.GOOGLE_API_KEY,
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