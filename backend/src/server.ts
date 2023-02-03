import express, { Request } from "express";
import * as fs from "fs-extra";
import * as path from "path";
import cors from "cors";
import { IAsset } from "./lib/asset";
import { Readable } from "stream";
import { ObjectId, Db } from "mongodb";

//
// Starts the REST API.
//
export async function createServer(db: Db) {

    await fs.ensureDir("uploads");
    await fs.ensureDir("thumbs");

    const assetCollections = db.collection<IAsset>("assets");

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

    app.post("/asset", async (req, res) => {

        const assetId = new ObjectId();
        const metadata = JSON.parse(getHeader(req, "metadata"));
        const fileName = getValue<string>(metadata, "fileName");
        const contentType = getValue<string>(metadata, "contentType");
        const thumbContentType = getValue<string>(metadata, "thumbContentType");
        const width = getValue<number>(metadata, "width");
        const height = getValue<number>(metadata, "height");
        const hash = getValue<string>(metadata, "hash");
        const thumbnail = getHeader(req, "thumbnail");
        
        const localFileName = path.join("uploads", assetId.toString());
        await streamToStorage(localFileName, req);

        const thumbFileName = path.join("thumbs", assetId.toString());
        await fs.writeFile(thumbFileName, thumbnail, "base64");

        const newAsset: IAsset = {
            _id: assetId,
            origFileName: fileName,
            contentType: contentType,
            thumbContentType: thumbContentType,
            src: `/asset?id=${assetId}`,
            thumb: `/asset?id=${assetId}`,
            width: width,
            height: height,
            hash: hash,
        };

        if (metadata.location) {
            newAsset.location = metadata.location; 
        }

        if (metadata.properties) {
            newAsset.properties = metadata.properties;
        }

        await assetCollections.insertOne(newAsset);

        res.json({
            assetId: assetId,
        });
    });

    app.get("/asset", async (req, res) => {

        const assetId = req.query.id as string;
        if (!assetId) {
            throw new Error(`Asset ID not specified in query parameters.`);
        }

        const localFileName = path.join("uploads", assetId);
        const asset = await assetCollections.findOne({ _id: new ObjectId(assetId) });
        if (!asset) {
            res.sendStatus(404);
            return;
        }

        res.writeHead(200, {
            "Content-Type": asset.contentType,
        });

        const fileReadStream = fs.createReadStream(localFileName);
        fileReadStream.pipe(res);
    });

    app.get("/thumb", async (req, res) => {

        const assetId = req.query.id as string;
        if (!assetId) {
            throw new Error(`Asset ID not specified in query parameters.`);
        }

        const localFileName = path.join("thumbs", assetId);
        const asset = await assetCollections.findOne({ _id: new ObjectId(assetId) });
        if (!asset) {
            res.sendStatus(404);
            return;
        }

        res.writeHead(200, {
            "Content-Type": asset.thumbContentType,
        });

        const fileReadStream = fs.createReadStream(localFileName);
        fileReadStream.pipe(res);
    });

    app.get("/check-asset", async (req, res) => {

        const hash = req.query.hash as string;
        if (!hash) {
            throw new Error(`Hash not specified in query parameters.`);
        }
        const asset = await assetCollections.findOne({ hash: hash });
        if (asset) {
            res.sendStatus(200);
        }
        else {
            res.sendStatus(404);
        }
    });

    app.get("/assets", async (req, res) => {

        const skip = getIntQueryParam(req, "skip");
        const limit = getIntQueryParam(req, "limit");

        const assets = await assetCollections.find({})
            .skip(skip)
            .limit(limit)
            .toArray();
        res.json({
            assets: assets,
        });
    });

    return app;
}

//
// Streams an input stream to local file storage.
//
function streamToStorage(localFileName: string, inputStream: Readable) {
    return new Promise<void>((resolve, reject) => {
        const fileWriteStream = fs.createWriteStream(localFileName);
        inputStream.pipe(fileWriteStream)
            .on("error", (err: any) => {
                reject(err);
            })
            .on("finish", () => {
                resolve();
            });
    });
}