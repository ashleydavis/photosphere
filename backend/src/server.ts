import express from "express";
import * as fs from "fs";
import * as path from "path";
import cors from "cors";
import { IAsset } from "./lib/asset";
import { Readable } from "stream";
import { ObjectId, Db } from "mongodb";

//
// Starts the REST API.
//
export function createServer(db: Db) {
    const assetCollections = db.collection<IAsset>("assets");

    const app = express();
    app.use(cors());

    app.post("/asset", async (req, res) => {

        const assetId = new ObjectId();
        const fileName = req.headers["file-name"];
        const contentType = req.headers["content-type"];
        const width = parseInt(req.headers["width"] as string);
        const height = parseInt(req.headers["height"] as string);
        const hash = req.headers["hash"];
        const localFileName = path.join(__dirname, "../uploads", assetId.toString());

        await streamToStorage(localFileName, req);

        await assetCollections.insertOne({
            _id: assetId,
            origFileName: fileName as string,
            contentType: contentType!,
            src: `/asset?id=${assetId}`,
            thumb: `/asset?id=${assetId}`,
            width: width,
            height: height,
            hash: hash as string,
        });

        res.json({
            assetId: assetId,
        });
    });

    app.get("/asset", async (req, res) => {

        const assetId = req.query.id as string;
        const localFileName = path.join(__dirname, "../uploads", assetId);
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

    app.get("/check-asset", async (req, res) => {

        const hash = req.query.hash as string;
        const asset = await assetCollections.findOne({ hash: hash });
        if (asset) {
            res.sendStatus(200);
        }
        else {
            res.sendStatus(404);
        }
    });

    app.get("/assets", async (req, res) => {

        const assets = await assetCollections.find({}).toArray();
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