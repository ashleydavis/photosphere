import express, { Request } from "express";
import cors from "cors";
import { IAsset } from "./lib/asset";
import { ObjectId, Db } from "mongodb";
import dayjs from "dayjs";
import { IStorage } from "./services/storage";

const API_KEY = process.env.API_KEY;

//
// Starts the REST API.
//
export async function createServer(db: Db, now: () => Date, storage: IStorage) {

    await storage.init();

    const assetsCollection = db.collection<IAsset>("assets");
    await assetsCollection.createIndex({ searchText: "text" });

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
    // Uploads metadata for an asset and allocats a new asset id.
    //
    app.post("/metadata", express.json(), async (req, res) => {

        const assetId = new ObjectId();
        const metadata = req.body;
        const fileName = getValue<string>(metadata, "fileName");
        const width = getValue<number>(metadata, "width");
        const height = getValue<number>(metadata, "height");
        const hash = getValue<string>(metadata, "hash");
        const fileDate = dayjs(getValue<string>(metadata, "fileDate")).toDate();
        const labels = metadata.labels || [];

        const newAsset: IAsset = {
            _id: assetId,
            origFileName: fileName,
            width: width,
            height: height,
            hash: hash,
            fileDate: fileDate,
            sortDate: fileDate,
            uploadDate: now(),
            labels: labels,
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
    // Uploads a new asset.
    //
    app.post("/asset", async (req, res) => {
        
        const assetId = new ObjectId(getHeader(req, "id"));
        const contentType = getHeader(req, "content-type");
        
        await storage.write("original", assetId.toString(), contentType, req);

        await assetsCollection.updateOne({ _id: assetId }, { $set: { assetContentType:  contentType } });

        res.json({
            assetId: assetId,
        });
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
        if (!asset || !asset.assetContentType) {
            res.sendStatus(404);
            return;
        }

        res.writeHead(200, {
            "Content-Type": asset.assetContentType,
        });

        const stream = storage.read("original", assetId);
        stream.pipe(res);
    });

    //
    // Uploads a thumbnail for a particular asset.
    //
    app.post("/thumb", async (req, res) => {
        
        const assetId = new ObjectId(getHeader(req, "id"));
        const contentType = getHeader(req, "content-type");

        await storage.write("thumb", assetId.toString(), contentType, req);

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
        if (!asset || (!asset.thumbContentType && !asset.assetContentType)) {
            // The asset doesn't exist or it's content was never uploaded.
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
    
            const stream = await storage.read("thumb", assetId);
            stream.pipe(res);
        }
        else {
            // 
            // No thumbnail, return the original asset.
            //
            res.writeHead(200, {
                "Content-Type": asset.assetContentType,
            });
    
            const stream = await storage.read("original", assetId);
            stream.pipe(res);
        }
    });

    //
    // Uploads a display version for a particular asset.
    //
    app.post("/display", async (req, res) => {
        
        const assetId = new ObjectId(getHeader(req, "id"));
        const contentType = getHeader(req, "content-type");
        
        await storage.write("display", assetId.toString(), contentType, req);

        await assetsCollection.updateOne({ _id: assetId }, { $set: { displayContentType:  contentType } });
        
        res.sendStatus(200);
    });

    //
    // Gets the display version for an asset by id.
    //
    app.get("/display", async (req, res) => {

        const assetId = req.query.id as string;
        if (!assetId) {
            throw new Error(`Asset ID not specified in query parameters.`);
        }

        const asset = await assetsCollection.findOne({ _id: new ObjectId(assetId) });
        if (!asset || (!asset.displayContentType && !asset.assetContentType)) {
            // The asset doesn't exist or it's content was never uploaded.
            res.sendStatus(404);
            return;
        }

        if (asset.displayContentType) {
            //
            // Return the display version of the asset.
            //
            res.writeHead(200, {
                "Content-Type": asset.displayContentType,
            });
    
            const stream = await storage.read("display", assetId);
            stream.pipe(res);
        }
        else {
            // 
            // No display asset, return the original asset.
            //
            res.writeHead(200, {
                "Content-Type": asset.assetContentType,
            });
    
            const stream = await storage.read("original", assetId);
            stream.pipe(res);
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
    // Sets a description for the asset.
    //
    app.post("/asset/description", express.json(), async (req, res) => {

        const id = new ObjectId(getValue<string>(req.body, "id"));
        const description = getValue<string>(req.body, "description");
        await assetsCollection.updateOne(
            { _id: id },
            {
                $set: {
                    description: description,
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

        const query: any = {};
        
        if (search) {
            query.$text = {
                $search: search.toLowerCase(),
            };
        }        

        const assets = await assetsCollection.find(query)
            .sort({ sortDate: -1 })
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
            // console.log(`Can't update search text for asset ${assetId}, asset doesn't exist.`);
            return;
        }

        let searchText = "";

        searchText += asset.origFileName + " ";

        if (asset.location) {
            searchText += " " + asset.location.toLowerCase();
        }

        if (asset.labels) {
            for (const label of asset.labels) {
                searchText += " " + label;
            }
        }    

        if (asset.description) {
            searchText += " " + asset.description;
        }

        await assetsCollection.updateOne(
            { _id: assetId },
            {
                $set: {
                    searchText: searchText,
                },
            }
        );

        // console.log(`Updated search text for asset ${assetId} to ${searchText}`);
    }

    return app;
}

