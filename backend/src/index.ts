const fs = require("fs");
const path = require("path");
const express = require("express");
const { MongoClient, ObjectId } = require('mongodb');
const cors = require("cors");

const PORT = process.env.PORT;
if (!PORT) {
    throw new Error(`Set environment variable PORT.`);
}

async function main() {

    const dbName = "photosphere";

    const DB_CONNECTION_STRING = process.env.DB_CONNECTION_STRING;
    if (DB_CONNECTION_STRING === undefined) {
        throw new Error(`Set environment variable DB_CONNECTION_STRING.`);
    }

    const client = new MongoClient(DB_CONNECTION_STRING);
    await client.connect();

    const db = client.db(dbName);
    const assetCollections = db.collection("assets");

    const app = express();
    app.use(cors());

    app.post("/asset", async (req, res) => {
	
        const assetId = new ObjectId();
        const fileName = req.headers["file-name"];
        const contentType = req.headers["content-type"];
        const width = parseInt(req.headers["width"]);
        const height = parseInt(req.headers["height"]);
        const hash = req.headers["hash"];
        const localFileName = path.join(__dirname, "../uploads", assetId.toString());
    
        await streamToStorage(localFileName, req);    
    
        await assetCollections.insertOne({
            _id: assetId,
            origFileName: fileName,
            contentType: contentType,
            src: `/asset?id=${assetId}`,
            thumb: `/asset?id=${assetId}`,
            width: width,
            height: height,
            hash: hash,
        });
    
        res.json({
            assetId: assetId,
        });
    });

    app.get("/asset", async (req, res) => {

        const assetId = req.query.id;
    
        const localFileName = path.join(__dirname, "../uploads", assetId);
    
        const asset = await assetCollections.findOne({ _id: new ObjectId(assetId) });
    
        res.writeHead(200, {
            "Content-Type": asset.contentType,
        });
    
        const fileReadStream = fs.createReadStream(localFileName);
        fileReadStream.pipe(res);
    });

    app.get("/check-asset", async (req, res) => {
        
        const hash = req.query.hash;
        const asset = await assetCollections.findOne({ hash: hash });
        if (asset) {
            res.sendStatus(200);
        }
        else {
            res.sendStatus(404);
        }    
    });

    app.get("/assets", async (req, res) => {

        const assets = await assetCollections.find().toArray();
        res.json({
            assets: assets,
        });
    });    

    app.listen(PORT, () => {
        console.log(`Example app listening on port ${PORT}`);
    });
}

main()
    .catch(err => {
        console.error(`Something went wrong.`);
        console.error(err);
        process.exit(1);
    });

//
// Streams an input stream to local file storage.
//
function streamToStorage(localFileName, inputStream) {
    return new Promise<void>((resolve, reject) => {
        const fileWriteStream = fs.createWriteStream(localFileName);
        inputStream.pipe(fileWriteStream)
            .on("error", err => {
                reject(err);
            })
            .on("finish", () => {
                resolve();
            });
    });
}