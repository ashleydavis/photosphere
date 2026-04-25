import { pipeline } from "stream/promises";
import express from "express";
import type { Request, Response, Application } from "express";
import { createServer, type Server } from "http";
import { createStorage, loadEncryptionKeysFromPem, type IStorage } from "storage";
import {
    applyDatabaseOps,
    createLazyDatabaseStorage,
    streamAsset,
    writeAssetStream,
    resolveStorageCredentials,
} from "api";
import type { IDatabaseOp } from "defs";
import { type IUuidGenerator, type ITimestampProvider, log } from "utils";

//
// JSON body for POST /apply-database-ops (only ops; UUID/timestamp/session come from the server).
//
interface IApplyDatabaseOpsRequestBody {
    //
    // Metadata operations from the client; passed as ops to applyDatabaseOps.
    //
    ops: IDatabaseOp[];
}

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

    //
    // Write-lock owner for apply-database-ops (see acquireWriteLock). 
    //
    sessionId: string;

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
    const { port, app: existingApp, uuidGenerator, timestampProvider, sessionId } = options;

    //
    // Cache of lazy database storage instances keyed by database path.
    // Avoids recreating storage (and re-reading the config/merkle-tree files) on every asset request.
    //
    const storageCache = new Map<string, IStorage>();

    //
    // Returns a cached lazy storage instance for the given database path, creating one if needed.
    //
    async function getAssetStorage(databasePath: string): Promise<IStorage> {
        const cached = storageCache.get(databasePath);
        if (cached) {
            return cached;
        }
        const { s3Config, encryptionKeyPems } = await resolveStorageCredentials(databasePath);
        const { options: storageOptions } = await loadEncryptionKeysFromPem(encryptionKeyPems);
        const storage = await createLazyDatabaseStorage(databasePath, s3Config, storageOptions);
        storageCache.set(databasePath, storage);
        return storage;
    }

    //
    // Helper function to load an asset and return it as a stream.
    // databasePath parameter is the path to the database directory.
    //
    async function loadAssetStream(assetId: string, assetType: string, databasePath: string): Promise<NodeJS.ReadableStream> {
        const assetStorage = await getAssetStorage(databasePath);
        return await streamAsset(assetStorage, assetId, assetType);
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
    app.get("/asset", express.json(), async (req: Request, res: Response) => {
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

        // log.info(`Loading asset stream ${assetId} of type ${assetType} from database ${databasePath}`);

        try {
            const assetStream = await loadAssetStream(assetId, assetType, databasePath);
            
            res.setHeader("Content-Type", "application/octet-stream");
            await pipeline(assetStream, res);
        }
        catch (error: any) {
            log.exception(`Error loading asset ${assetId}`, error);
            if (!res.headersSent) {
                res.status(500).send("Error loading asset");
            }
        }
    });

    //
    // POST /asset — writes raw bytes for one asset variant (thumb | display | asset) into a database directory.
    // Same query params as GET: id, type, db. Body: raw bytes. Content-Type: MIME of the blob.
    // Used when moving/copying assets between databases (gallery) so file data matches metadata applied via apply-database-ops.
    //
    app.post("/asset", async (req: Request, res: Response) => {
        
        const assetId = req.query.id as string | undefined;
        const databasePath = req.query.db as string | undefined;
        const assetType = req.query.type as string | undefined;

        if (!assetId || !databasePath || !assetType) {
            res.status(400).send("Missing id, db, or type query parameter.");
            return;
        }

        try {
            const { storage, rawStorage } = createStorage(databasePath, undefined, undefined);
            await writeAssetStream(
                storage,
                rawStorage,
                sessionId,
                assetId,
                assetType,
                req.headers["content-type"],
                req,
                req.headers["content-type"] && parseInt(req.headers["content-length"] as string) || undefined
            );
            res.status(204).end();
        }
        catch (error: any) {
            log.exception(`Error storing asset ${assetId} (${assetType})`, error);
            res.status(500).send(error?.message || "Error storing asset");
        }
    });

    //
    // POST /apply-database-ops — applies metadata changes to one or more on-disk databases (BSON collections).
    // Used by the gallery UI to persist set / push / pull operations via the same local server as /asset.
    //
    // Request body: JSON { ops: IDatabaseOp[] } where each op targets a database path (databaseId), collection, record id, and operation.
    // Responses: 400 if ops is missing or not an array; 204 on success; 500 if applying ops fails.
    //
    app.post("/apply-database-ops", express.json(), async (req: Request, res: Response) => {
        const body = req.body as IApplyDatabaseOpsRequestBody;
        const ops = body.ops;
        if (!ops || !Array.isArray(ops)) {
            res.status(400).send("Request body must be a JSON object with an \"ops\" array.");
            return;
        }

        try {
            await applyDatabaseOps(uuidGenerator, timestampProvider, sessionId, ops);
            res.status(204).end();
        }
        catch (error: any) {
            log.exception("Error applying database ops", error);
            if (!res.headersSent) {
                res.status(500).send(error?.message || "Error applying database ops");
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
        server.listen(port, "127.0.0.1", () => {
            log.info(`Asset server running on http://localhost:${port}`);
            resolve();
        });
    });

    return {
        app,
        server,
    };
}

