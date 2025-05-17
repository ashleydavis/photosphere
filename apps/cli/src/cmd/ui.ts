import path from 'path';
import fs from 'fs';
import AdmZip from "adm-zip";
import os from 'os';
import { createServer, SingleMediaFileDatabaseProvider } from 'rest-api';
import { createStorage, loadEncryptionKeys } from "storage";
import { registerTerminationCallback } from "node-utils";

// @ts-ignore
import pfe from  "../../pfe.zip" with { type: "file" } ;

//
// Starts the Photosphere ui.
//
export async function uiCommand(dbDir: string, options: any): Promise<void> {
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

    const { options: storageOptions } = await loadEncryptionKeys(options.key, options.generateKey || false, "source");
    const { storage: assetStorage } = createStorage(dbDir, storageOptions);        
    const { storage: metadataStorage } = createStorage(dbDir);
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
       console.log("Photosphere editor started at http://localhost:3000");
    });
}