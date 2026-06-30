import { pipeline } from "stream/promises";
import express from "express";
import type { Request, Response, Application } from "express";
import { log } from "utils";
import type { IDatabaseOp } from "api";
import type { IAssetServerCore } from "./asset-server-core";

//
// JSON body for POST /apply-database-ops (only ops; UUID/timestamp/session come from the server).
//
interface IApplyDatabaseOpsRequestBody {
    //
    // Metadata operations from the client; passed as ops to the core's applyDatabaseOps.
    //
    ops: IDatabaseOp[];
}

//
// Attaches the asset server HTTP routes to an express application, delegating all work to the
// transport-agnostic core. The routes are byte-for-byte the same as the original asset server:
// GET /asset, POST /asset, and POST /apply-database-ops. CORS middleware is added only when
// enableCors is true (i.e. when the asset server owns the app rather than attaching to an existing one).
//
export function attachAssetServerRoutes(app: Application, core: IAssetServerCore, enableCors: boolean): void {

    // Enable CORS for all routes (only when this server owns the app).
    if (enableCors) {
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

        try {
            const assetStream = await core.serveAsset(assetId, assetType, databasePath);

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
            await core.writeAsset(
                assetId,
                assetType,
                databasePath,
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
            await core.applyDatabaseOps(ops);
            res.status(204).end();
        }
        catch (error: any) {
            log.exception("Error applying database ops", error);
            if (!res.headersSent) {
                res.status(500).send(error?.message || "Error applying database ops");
            }
        }
    });
}
