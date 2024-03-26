import express, { Request } from "express";
import cors from "cors";
import { IAsset } from "./lib/asset";
import dayjs from "dayjs";
import { IStorage } from "./services/storage";
import { v4 as uuid } from 'uuid';
import { IDatabase } from "./services/database";

const API_KEY = process.env.API_KEY;

//
// Starts the REST API.
//
export async function createServer(now: () => Date, database: IDatabase<IAsset>, storage: IStorage) {

    const app = express();
    app.use(cors());

    if (API_KEY) {
        //
        // Authenticates with an API key.
        // All routes after this must provide the API key.
        //
        app.use((req, res, next) => {
            if (req.query.key === API_KEY || req.headers.key === API_KEY) {
                // Allow the request.
                next();
                return;
            }
            
            // Disallow the request.
            res.sendStatus(403);
        });
    }

    //
    // Gets the value of a header from the request.
    // Throws an error if the header is not present.
    //
    function getHeader(req: Request, name: string): string {
        const value = req.headers[name] as string;
        if (!value) {
            throw new Error(`Expected header ${name}`);
        }

        return value;
    }

    //
    // Gets a query param as a number.
    // Throws an error if the value doesn't parse.
    //
    function getIntQueryParam(req: Request, name: string): number {
        const value = parseInt((req.query as any)[name]);
        if (Number.isNaN(value)) {
            throw new Error(`Failed to parse int query param ${name}`);
        }
        return value;
    }

    //
    // Gets the value of a field from an object.
    // Throws an error if the field is not present.
    //
    function getValue<T>(obj: any, name: string): T {
        const value = obj[name] as T;
        if (value === undefined) {
            throw new Error(`Expected field ${name}`);
        }

        return value;
    }

    //
    // Tracks a new hash to an asset id.
    //
    async function updateHash(hash: string, assetId: string): Promise<void> {
        await storage.write("hash", hash, "text/plain", Buffer.from(assetId));
    }

    //
    // Reads the assetId that is linked to a hash.
    //
    async function readHash(hash: string): Promise<string | undefined> {
        const buffer = await storage.read("hash", hash);
        if (!buffer) {
            return undefined;
        }
        return buffer.toString("utf-8");
    }

    //
    // A handler for errors in async route handlers.
    //
    function asyncErrorHandler(handler: (req: Request, res: express.Response) => Promise<void>) {
        return async (req: Request, res: express.Response) => {
            try {
                await handler(req, res);
            }
            catch (err: any) {
                console.error(`An error occured handling ${req.method} ${req.path}`);
                console.error(err);
                res.sendStatus(500);;
            }
        };
    }

    //
    // Uploads metadata for an asset and allocates a new asset id.
    //
    app.post("/metadata", express.json(), asyncErrorHandler(async (req, res) => {

        const metadata = req.body;
        const fileName = getValue<string>(metadata, "fileName");
        const width = getValue<number>(metadata, "width");
        const height = getValue<number>(metadata, "height");
        const hash = getValue<string>(metadata, "hash");
        const fileDate = dayjs(getValue<string>(metadata, "fileDate")).toDate();
        const labels = metadata.labels || [];
        const photoDate = metadata.photoDate ? dayjs(metadata.photoDate).toDate() : undefined;
        const uploadDate = now();
        const sortDate = photoDate || fileDate || uploadDate;
        const assetId = uuid();

        const newAsset: IAsset = {
            _id: assetId,
            origFileName: fileName,
            width: width,
            height: height,
            hash: hash,
            fileDate: fileDate,
            photoDate: photoDate,
            sortDate: sortDate,
            uploadDate: uploadDate,
            labels: labels,
        };

        if (metadata.location) {
            newAsset.location = metadata.location; 
        }

        if (metadata.properties) {
            newAsset.properties = metadata.properties;
        }

        await database.setOne(assetId, newAsset);

        await updateHash(hash, assetId);

        res.json({
            assetId: assetId,
        });
    }));

    //
    // Gets the metadata for an asset by id.
    //
    app.get("/metadata", asyncErrorHandler(async (req, res) => {

        const assetId = req.query.id as string;
        if (!assetId) {
            throw new Error(`Asset ID not specified in query parameters.`);
        }

        const metadata = await database.getOne(assetId);
        if (!metadata) {
            res.sendStatus(404);
            return;
        }

        res.json(metadata);
    }));

    //
    // Uploads a new asset.
    //
    app.post("/asset", asyncErrorHandler(async (req, res) => {
        
        const assetId = getHeader(req, "id");
        const contentType = getHeader(req, "content-type");
        
        await storage.writeStream("original", assetId.toString(), contentType, req);

        await database.updateOne(assetId, { assetContentType: contentType });

        res.sendStatus(200);
    })); 

    //
    // Gets a particular asset by id.
    //
    app.get("/asset", asyncErrorHandler(async (req, res) => {

        const assetId = req.query.id as string;
        if (!assetId) {
            res.sendStatus(400);
            return;
        }

        const assetInfo = await storage.info("original", assetId);
        if (!assetInfo) {
            res.sendStatus(404);
            return;
        }

        res.writeHead(200, {
            "Content-Type": assetInfo.contentType,
        });

        const stream = storage.readStream("original", assetId);
        stream.pipe(res);
    }));

    //
    // Uploads a thumbnail for a particular asset.
    //
    app.post("/thumb", asyncErrorHandler(async (req, res) => {
        
        const assetId = getHeader(req, "id");
        const contentType = getHeader(req, "content-type");

        await storage.writeStream("thumb", assetId.toString(), contentType, req);

        await database.updateOne(assetId, { thumbContentType: contentType });
        
        res.sendStatus(200);
    }));

    //
    // Gets the thumb for an asset by id.
    //
    app.get("/thumb", asyncErrorHandler(async (req, res) => {

        const assetId = req.query.id as string;
        if (!assetId) {
            res.sendStatus(400);
            return;
        }

        const assetInfo = await storage.info("thumb", assetId);
        if (!assetInfo) {
            res.sendStatus(404);
            return;
        }

        res.writeHead(200, {
            "Content-Type": assetInfo.contentType,
        });

        const stream = await storage.readStream("thumb", assetId);
        stream.pipe(res);
    }));

    //
    // Uploads a display version for a particular asset.
    //
    app.post("/display", asyncErrorHandler(async (req, res) => {
        
        const assetId = getHeader(req, "id");
        const contentType = getHeader(req, "content-type");
        
        await storage.writeStream("display", assetId.toString(), contentType, req);

        await database.updateOne(assetId, { displayContentType: contentType });

        res.sendStatus(200);
    }));

    //
    // Gets the display version for an asset by id.
    //
    app.get("/display", asyncErrorHandler(async (req, res) => {

        const assetId = req.query.id as string;
        if (!assetId) {
            res.sendStatus(400);
            return;
        }

        const assetInfo = await storage.info("display", assetId);
        if (!assetInfo) {
            res.sendStatus(404);
            return;
        }

        //
        // Return the display version of the asset.
        //
        res.writeHead(200, {
            "Content-Type": assetInfo.contentType,
        });

        const stream = await storage.readStream("display", assetId);
        stream.pipe(res);
    }));

    //
    // Adds a label to an asset.
    //
    app.post("/asset/add-label", express.json(), asyncErrorHandler(async (req, res) => {

        const id = getValue<string>(req.body, "id");
        const label = getValue<string>(req.body, "label");

        const metadata = await database.getOne(id);
        if (!metadata) {
            res.sendStatus(404);
            return;
        }

        if (!metadata.labels) {
            metadata.labels = [];
        }
        metadata.labels.push(label);
        await database.setOne(id, metadata);

        res.sendStatus(200);
    }));

    //
    // Removes a label from an asset.
    //
    app.post("/asset/remove-label", express.json(), asyncErrorHandler(async (req, res) => {

        const id = getValue<string>(req.body, "id");
        const label = getValue<string>(req.body, "label");

        const metadata = await database.getOne(id);
        if (!metadata) {
            res.sendStatus(404);
            return;
        }

       if (metadata.labels) {
            metadata.labels = metadata.labels.filter(l => l !== label);
            await database.setOne(id, metadata);
        }

        res.sendStatus(200);
    }));

    //
    // Sets a description for the asset.
    //
    app.post("/asset/description", express.json(), asyncErrorHandler(async (req, res) => {

        const id = getValue<string>(req.body, "id");
        const description = getValue<string>(req.body, "description");

        await database.updateOne(id, { description });
                
        res.sendStatus(200);
    }));

    //
    // Checks if an asset has already been upload by its hash.
    //
    app.get("/check-asset", asyncErrorHandler(async (req, res) => {

        const hash = req.query.hash as string;
        if (!hash) {
            res.sendStatus(400);
            return;
        }

        // Read the hash map.
        const assetId = await readHash(hash);
        if (assetId) {
            // The asset exists.
            res.json({ assetId: assetId });
        }
        else {
            // The asset doesn't exist.
            res.json({ assetId: undefined });
        }
    }));

    //
    // Gets a paginated list of all assets.
    //
    app.get("/assets", asyncErrorHandler(async (req, res) => {

        const next = req.query.next as string;

        const result = await storage.list("metadata", 1000, next);
        const assets = await Promise.all(result.assetIds.map(
            async assetId => {
                const asset = await database.getOne(assetId);
                return asset;
            }
        ));

        res.json({
            assets: assets,
            next: result.continuation,
        });    
    }));

    return app;
}
