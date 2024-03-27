import express, { Request } from "express";
import cors from "cors";
import { IAsset } from "./lib/asset";
import dayjs from "dayjs";
import { v4 as uuid } from 'uuid';
import { IAssetDatabase } from "./services/asset-database";

//
// Starts the REST API.
//
export async function createServer(now: () => Date, assetDatabase: IAssetDatabase) {

    const app = express();
    app.use(cors());

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
    // A handler for errors in async route handlers.
    //
    function asyncErrorHandler(handler: (req: Request, res: express.Response) => Promise<void>) {
        return async (req: Request, res: express.Response) => {
            try {
                await handler(req, res);
            }
            catch (err: any) {
                console.error(`An error occured handling ${req.method} ${req.path}`);
                console.error(err.stack);
                res.sendStatus(500);
            }
        };
    }

    //
    // Uploads metadata for an asset and allocates a new asset id.
    //
    app.post("/metadata", express.json(), asyncErrorHandler(async (req, res) => {

        const metadata = req.body;
        const accountId = getValue<string>(metadata, "acc");
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

        await assetDatabase.addMetadata(accountId, assetId, hash, newAsset);

        res.json({
            assetId: assetId,
        });
    }));

    //
    // Gets the metadata for an asset by id.
    //
    app.get("/metadata", asyncErrorHandler(async (req, res) => {

        const assetId = req.query.id as string;
        const accountId = req.query.acc as string;
        if (!assetId || !accountId) {
            res.sendStatus(400);
            return;
        }

        const metadata = await assetDatabase.getMetadata(accountId, assetId);
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
        const accountId = getHeader(req, "acc");
        const contentType = getHeader(req, "content-type");
        await assetDatabase.uploadOriginal(accountId, assetId, contentType, req);
        res.sendStatus(200);
    })); 

    //
    // Gets a particular asset by id.
    //
    app.get("/asset", asyncErrorHandler(async (req, res) => {

        const assetId = req.query.id as string;
        const accountId = req.query.acc as string;
        if (!assetId || !accountId) {
            res.sendStatus(400);
            return;
        }

        const assetStream = await assetDatabase.streamOriginal(accountId, assetId);
        if (!assetStream) {
            res.sendStatus(404);
            return;
        }

        res.writeHead(200, {
            "Content-Type": assetStream.contentType,
        });

        assetStream.stream.pipe(res);
    }));

    //
    // Uploads a thumbnail for a particular asset.
    //
    app.post("/thumb", asyncErrorHandler(async (req, res) => {
        const assetId = getHeader(req, "id");
        const accountId = getHeader(req, "acc");
        const contentType = getHeader(req, "content-type");
        await assetDatabase.uploadThumbnail(accountId, assetId, contentType, req);
        res.sendStatus(200);
    }));

    //
    // Gets the thumb for an asset by id.
    //
    app.get("/thumb", asyncErrorHandler(async (req, res) => {

        const assetId = req.query.id as string;
        const accountId = req.query.acc as string;
        if (!assetId || !accountId) {
            res.sendStatus(400);
            return;
        }

        const assetStream = await assetDatabase.streamThumbnail(accountId, assetId);
        if (!assetStream) {
            res.sendStatus(404);
            return;
        }

        res.writeHead(200, {
            "Content-Type": assetStream.contentType,
        });

        assetStream.stream.pipe(res);
``    }));

    //
    // Uploads a display version for a particular asset.
    //
    app.post("/display", asyncErrorHandler(async (req, res) => {
        const assetId = getHeader(req, "id");
        const accountId = getHeader(req, "acc");
        const contentType = getHeader(req, "content-type");
        await assetDatabase.uploadDisplay(accountId, assetId, contentType, req);
        res.sendStatus(200);
    }));

    //
    // Gets the display version for an asset by id.
    //
    app.get("/display", asyncErrorHandler(async (req, res) => {

        const assetId = req.query.id as string;
        const accountId = req.query.acc as string;
        if (!assetId || !accountId) {
            res.sendStatus(400);
            return;
        }

        const assetStream = await assetDatabase.streamDisplay(accountId, assetId);
        if (!assetStream) {
            res.sendStatus(404);
            return;
        }

        res.writeHead(200, {
            "Content-Type": assetStream.contentType,
        });

        assetStream.stream.pipe(res);
    }));

    //
    // Adds a label to an asset.
    //
    app.post("/asset/add-label", express.json(), asyncErrorHandler(async (req, res) => {
        const id = getValue<string>(req.body, "id");
        const accountId = getValue<string>(req.body, "acc");
        const label = getValue<string>(req.body, "label");
        await assetDatabase.addLabel(accountId, id, label);
        res.sendStatus(200);
    }));

    //
    // Removes a label from an asset.
    //
    app.post("/asset/remove-label", express.json(), asyncErrorHandler(async (req, res) => {
        const id = getValue<string>(req.body, "id");
        const accountId = getValue<string>(req.body, "acc");
        const label = getValue<string>(req.body, "label");
        await assetDatabase.removeLabel(accountId, id, label);
        res.sendStatus(200);
    }));

    //
    // Sets a description for the asset.
    //
    app.post("/asset/description", express.json(), asyncErrorHandler(async (req, res) => {
        const id = getValue<string>(req.body, "id");
        const accountId = getValue<string>(req.body, "acc");
        const description = getValue<string>(req.body, "description");
        await assetDatabase.setDescription(accountId, id, description);
        res.sendStatus(200);
    }));

    //
    // Checks if an asset has already been upload by its hash.
    //
    app.get("/check-asset", asyncErrorHandler(async (req, res) => {

        const hash = req.query.hash as string;
        const accountId = req.query.acc as string;
        if (!hash || !accountId) {
            res.sendStatus(400);
            return;
        }

        // Read the hash map.
        const assetId = await assetDatabase.checkAsset(accountId, hash);
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
        const accountId = req.query.acc as string;
        if (!accountId) {
            res.sendStatus(400);
            return;
        }

        const result = await assetDatabase.getAssets(accountId, next);
        res.json({
            assets: result.assets,
            next: result.next,
        });    
    }));

    return app;
}
