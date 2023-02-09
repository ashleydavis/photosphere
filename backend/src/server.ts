import express, { Request } from "express";
import * as fs from "fs-extra";
import * as path from "path";
import cors from "cors";
import { IAsset } from "./lib/asset";
import { Readable } from "stream";
import { ObjectId, Db } from "mongodb";
import dayjs from "dayjs";

//
// Starts the REST API.
//
export async function createServer(db: Db, now: () => Date) {

    await fs.ensureDir("uploads");
    await fs.ensureDir("thumbs");

    const assetsCollection = db.collection<IAsset>("assets");
    await assetsCollection.createIndex({ searchText: "text" });

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
    // Uploads a new asset.
    //
    app.post("/asset", async (req, res) => {

        const assetId = new ObjectId();
        const metadata = JSON.parse(getHeader(req, "metadata"));
        const fileName = getValue<string>(metadata, "fileName");
        const contentType = getValue<string>(metadata, "contentType");
        const width = getValue<number>(metadata, "width");
        const height = getValue<number>(metadata, "height");
        const hash = getValue<string>(metadata, "hash");
        const fileDate = dayjs(getValue<string>(metadata, "fileDate")).toDate();
        
        const localFileName = path.join("uploads", assetId.toString());
        await streamToStorage(localFileName, req);

        const newAsset: IAsset = {
            _id: assetId,
            origFileName: fileName,
            contentType: contentType,
            width: width,
            height: height,
            hash: hash,
            fileDate: fileDate,
            sortDate: fileDate,
            uploadDate: now(),
            labels: [],
        };

        if (metadata.location) {
            newAsset.location = metadata.location; 
        }

        if (metadata.properties) {
            newAsset.properties = metadata.properties;
        }

        if (metadata.photoDate) {
            newAsset.photoDate = dayjs(metadata.photoDate).toDate();
            newAsset.sortDate = newAsset.photoDate;
        }

        await assetsCollection.insertOne(newAsset);

        res.json({
            assetId: assetId,
        });

        await updateSearchText(assetId);
    });

    //
    // Gets a particular asset by id.
    //
    app.get("/asset", async (req, res) => {

        const assetId = req.query.id as string;
        if (!assetId) {
            throw new Error(`Asset ID not specified in query parameters.`);
        }

        const asset = await assetsCollection.findOne({ _id: new ObjectId(assetId) });
        if (!asset) {
            res.sendStatus(404);
            return;
        }

        res.writeHead(200, {
            "Content-Type": asset.contentType,
        });

        const localFileName = path.join("uploads", assetId);
        const fileReadStream = fs.createReadStream(localFileName);
        fileReadStream.pipe(res);
    });

    //
    // Uploads a thumbnail for a particular asset.
    //
    app.post("/thumb", async (req, res) => {
        
        const assetId = new ObjectId(getHeader(req, "id"));
        const localFileName = path.join("thumbs", assetId.toString());
        await streamToStorage(localFileName, req);

        const contentType = getHeader(req, "content-type");
        await assetsCollection.updateOne({ _id: assetId }, { $set: { thumbContentType:  contentType } });
        
        res.sendStatus(200);
    });

    //
    // Gets the thumb for an asset by id.
    //
    app.get("/thumb", async (req, res) => {

        const assetId = req.query.id as string;
        if (!assetId) {
            throw new Error(`Asset ID not specified in query parameters.`);
        }

        const asset = await assetsCollection.findOne({ _id: new ObjectId(assetId) });
        if (!asset) {
            res.sendStatus(404);
            return;
        }

        if (asset.thumbContentType) {
            //
            // Return the thumbnail.
            //
            res.writeHead(200, {
                "Content-Type": asset.thumbContentType,
            });
    
            const localFileName = path.join("thumbs", assetId);
            const fileReadStream = fs.createReadStream(localFileName);
            fileReadStream.pipe(res);
        }
        else {
            // 
            // No thumbnail, return the original asset.
            //
            res.writeHead(200, {
                "Content-Type": asset.contentType,
            });
    
            const localFileName = path.join("uploads", assetId);
            const fileReadStream = fs.createReadStream(localFileName);
            fileReadStream.pipe(res);
        }
    });

    //
    // Adds a label to an asset.
    //
    app.post("/asset/add-label", express.json(), async (req, res) => {

        const id = new ObjectId(getValue<string>(req.body, "id"));
        const label = getValue<string>(req.body, "label");
        await assetsCollection.updateOne(
            { _id: id },
            {
                $push: {
                    labels: label,
                },
            }
        );
        res.sendStatus(200);

        await updateSearchText(id);
    });

    //
    // Removes a label from an asset.
    //
    app.post("/asset/remove-label", express.json(), async (req, res) => {

        const id = new ObjectId(getValue<string>(req.body, "id"));
        const label = getValue<string>(req.body, "label");
        await assetsCollection.updateOne(
            { _id: id },
            {
                $pull: {
                    labels: label,
                },
            }
        );
        res.sendStatus(200);

        await updateSearchText(id);
    });

    //
    // Checks if an asset has already been upload by its hash.
    //
    app.get("/check-asset", async (req, res) => {

        const hash = req.query.hash as string;
        if (!hash) {
            throw new Error(`Hash not specified in query parameters.`);
        }
        
        const asset = await assetsCollection.findOne({ hash: hash });
        if (asset) {
            res.json({ assetId: asset._id });
        }
        else {
            res.json({ assetId: undefined });
        }
    });

    //
    // Gets a paginated list of all assets.
    //
    app.get("/assets", async (req, res) => {

        const search = req.query.search as string;
        const skip = getIntQueryParam(req, "skip");
        const limit = getIntQueryParam(req, "limit");

        const query: any = {};
        
        if (search) {
            query.$text = {
                $search: search.toLowerCase(),
            };
        }        

        const assets = await assetsCollection.find(query)
            .sort({ sortDate: -1 })
            .skip(skip)
            .limit(limit)
            .toArray();

        res.json({
            assets: assets,
        });
    });

    //
    // Build the search index for a single asset.
    //
    async function updateSearchText(assetId: ObjectId): Promise<void> {

        const asset = await assetsCollection.findOne({ _id: assetId });
        if (!asset) {
            // No asset.
            console.log(`Can't update search text for asset ${assetId}, asset doesn't exist.`);
            return;
        }

        let searchText = "";

        if (asset.location) {
            searchText += " " + asset.location.toLowerCase();
        }

        for (const label of asset.labels) {
            searchText += " " + label;
        }

        await assetsCollection.updateOne(
            { _id: assetId },
            {
                $set: {
                    searchText: searchText,
                },
            }
        );

        console.log(`Updated search text for asset ${assetId} to ${searchText}`);
    }

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