import express from "express";
import type { Request, Response, Application } from "express";
import { createServer, type Server } from "http";
import { createStorage } from "storage";
import { createMediaFileDatabase, loadDatabase, streamAsset } from "api/src/lib/media-file-database";
import { type IUuidGenerator, type ITimestampProvider, log } from "utils";

//
// Options for creating the asset server.
//
export interface IAssetServerOptions {
    //
    // Port to listen on (required if app is not provided).
    //
    port?: number;

    //
    // Existing Express app to attach routes to (optional).
    // If provided, routes will be attached to this app instead of creating a new one.
    //
    app?: Application;

    //
    // UUID generator to use.
    //
    uuidGenerator: IUuidGenerator;

    //
    // Timestamp provider to use.
    //
    timestampProvider: ITimestampProvider;

}

//
// Result from creating the asset server.
//
export interface IAssetServerResult {
    //
    // The Express application.
    //
    app: Application;

    //
    // The HTTP server (only if a new server was created).
    //
    server?: Server;
}

//
// Creates and starts an asset server.
//
export async function createAssetServer(options: IAssetServerOptions): Promise<IAssetServerResult> {
    const { port, app: existingApp, uuidGenerator, timestampProvider } = options;

    //
    // Helper function to load an asset and return it as a stream
    // databasePath parameter is the path to the database directory
    //
    async function loadAssetStream(assetId: string, assetType: string, databasePath: string): Promise<NodeJS.ReadableStream> {

        log.info(`Loading asset stream ${assetId} of type ${assetType} from database ${databasePath}`);
        
        // Create storage without encryption
        const { storage: assetStorage } = createStorage(databasePath, undefined, undefined);
        
        // Create database instance
        const database = createMediaFileDatabase(assetStorage, uuidGenerator, timestampProvider);
        
        // Load the database
        await loadDatabase(assetStorage, database.metadataCollection);
        
        // Stream the asset
        return streamAsset(assetStorage, assetId, assetType);
    }

    // Use existing app or create new one
    const app = existingApp || express();

    // Enable CORS for all routes (only if we created a new app)
    if (!existingApp) {
        app.use((req: Request, res: Response, next: express.NextFunction) => {
            res.header("Access-Control-Allow-Origin", "*");
            res.header("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS");
            res.header("Access-Control-Allow-Headers", "Origin, X-Requested-With, Content-Type, Accept");
            if (req.method === "OPTIONS") {
                res.sendStatus(200);
                return;
            }
            next();
        });
    }

    // Handle HTTP GET requests for assets
    app.get("/asset", async (req: Request, res: Response) => {
        const assetId = req.query.id as string;
        const databasePath = req.query.db as string;
        const assetType = req.query.type as string;

        if (!assetId) {
            res.status(400).send("Missing 'id' parameter");
            return;
        }

        if (!databasePath) {
            res.status(400).send("Missing 'db' parameter");
            return;
        }

        if (!assetType) {
            res.status(400).send("Missing 'type' parameter");
            return;
        }

        log.info(`Loading asset stream ${assetId} of type ${assetType} from database ${databasePath}`);

        try {
            const assetStream = await loadAssetStream(assetId, assetType, databasePath);
            
            res.setHeader("Content-Type", "application/octet-stream");
            assetStream.pipe(res);
        }
        catch (error: any) {
            log.exception(`Error loading asset ${assetId}`, error);
            if (!res.headersSent) {
                res.status(500).send("Error loading asset");
            }
        }
    });

    // If we have an existing app, don't create a new server
    if (existingApp) {
        return {
            app,
        };
    }

    // Create HTTP server from Express app
    if (!port) {
        throw new Error("Port is required when creating a new server");
    }

    const server = createServer(app);

    // Start server
    await new Promise<void>((resolve) => {
        server.listen(port, () => {
            log.info(`Asset server running on http://localhost:${port}`);
            resolve();
        });
    });

    return {
        app,
        server,
    };
}

