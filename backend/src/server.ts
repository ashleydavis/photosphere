import express, { Request, Response } from "express";
import cors from "cors";
import { auth } from "express-oauth2-jwt-bearer";
import { Db } from "mongodb";
import { IStorage } from "storage";
import { IUser, IDatabaseOp } from "defs";

declare global {
    namespace Express {
        interface Request {
            userId?: string;
            user?: IUser;
        }
    }
}

const dateFields = [
    "fileDate",
    "photoDate",
    "uploadDate",
];

const APP_MODE = process.env.APP_MODE;
if (!APP_MODE) {
    throw new Error("Expected APP_MODE environment variable set to 'readonly' or 'readwrite'");
}

const AUTH_TYPE = process.env.AUTH_TYPE;
if (!AUTH_TYPE) {
    throw new Error("Expected AUTH_TYPE environment variable set to 'auth0' or 'no-auth'");
}
else {
    if (!process.env.AUTH0_AUDIENCE) {
        throw new Error("Expected AUTH0_AUDIENCE environment variable");
    }

    if (!process.env.AUTH0_BASE_URL) {
        throw new Error("Expected AUTH0_BASE_URL environment variable");
    }
}

//
// Starts the REST API.
//
export async function createServer(now: () => Date, db: Db, storage: IStorage) {

    //
    // Make sure the metadata collection has the right indexes to stop the following error:
    //
    // MongoServerError: Executor error during find command :: caused by :: Sort exceeded memory limit of 104857600 bytes, but did not opt in to external sorting. Aborting operation. Pass allowDiskUse:true to opt in.
    //
    await db.collection("metadata").createIndex({ setId: 1, photoDate: -1 });

    const app = express();
    app.use(cors());

    app.get("/alive", (req, res) => {
        console.log("Server is alive.");
        res.sendStatus(200);
    });

    //
    // Extracts JWT from query parameters.
    //
    app.use((req, res, next) => {

        if (req.path === "/" || req.path === "/favicon.ico") {
            res.sendStatus(404);
            return;
        }

        next();
    });

    
    if (process.env.AUTH_TYPE === "auth0") {
        
        const checkJwt = auth({
            audience: process.env.AUTH0_AUDIENCE!,
            issuerBaseURL: process.env.AUTH0_BASE_URL!,
            tokenSigningAlg: 'RS256'        
        });

        //
        // Authenticates a JWT token.
        //
        app.use(checkJwt);

        //
        // Attaches user information to the request.
        //
        app.use(async (req, res, next) => {
            if (!req.auth?.payload.sub) {
                res.sendStatus(401);
                return;
            }

            let userId = req.auth.payload.sub;
            if (userId.startsWith("auth0|")) {
                // Removes the auth0| prefix the user id.
                userId = userId.substring(6);
            }
            const user = await db.collection<IUser>("users").findOne({ _id: userId });
            if (!user) {
                console.log(`User not found: ${userId}`);
                res.sendStatus(401);
                return;
            }

            req.userId = userId;
            req.user = Object.assign({}, user, {
                _id: userId,
            });
            next();
        });

    }
    else if (process.env.AUTH_TYPE === "no-auth") {
        //
        //
        // Attaches user information to the request.
        //
        app.use(async (req, res, next) => {
            req.userId = 'test-user'; //TOOD: This could be set by env var.

            const user = await db.collection<IUser>("users").findOne({ _id: req.userId });
            if (!user) {
                console.log(`User not found: ${req.userId}`);
                res.sendStatus(401);
                return;
            }

            req.user = user;
            next();
        });
    }
    else {
        throw new Error(`Unknown AUTH_TYPE: ${process.env.AUTH_TYPE}`);
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
    // A handler for errors in async route handlers.
    //
    function asyncErrorHandler(handler: (req: Request, res: Response) => Promise<void>) {
        return async (req: Request, res: Response) => {
            try {
                console.log(`Handling ${req.method} ${req.path}`);
                await handler(req, res);
                console.log(`Handled ${req.method} ${req.path}`);
            }
            catch (err: any) {
                console.error(`An error occured handling ${req.method} ${req.path}`);
                console.error(err.stack);
                res.sendStatus(500);
            }
        };
    }

    //
    // Gets the user's metadata.
    //
    app.get("/user", asyncErrorHandler(async (req, res) => {
        res.json(req.user);
    }));
    
    //
    // Applies a set of operations to the asset database.
    //
    app.post("/operations", express.json(), asyncErrorHandler(async (req, res) => {
        if (APP_MODE !== "readwrite") {
            res.sendStatus(403); // Forbidden in readonly mode.
            return;
        }

        const ops = getValue<IDatabaseOp[]>(req.body, "ops");
        for (const op of ops) {
            const recordCollection = db.collection(op.collectionName);
            if (op.op.type === "set") {

                //
                // Deserialize date fields.
                //
                const fields = Object.assign({}, op.op.fields);
                for (const dateField of dateFields) {
                    if (fields[dateField] !== undefined) {
                        fields[dateField] = new Date(fields[dateField]);
                    }
                }

                await recordCollection.updateOne(
                    { _id: op.recordId },
                    { $set: fields },
                    { upsert: true }
                );
            }
            else if (op.op.type === "push") {
                await recordCollection.updateOne(
                    { _id: op.recordId },
                    { 
                        $push: {
                            [op.op.field]: op.op.value,                           
                        },
                    },
                    { upsert: true }
                );
            }
            else if (op.op.type === "pull") {
                await recordCollection.updateOne(
                    { _id: op.recordId },
                    { 
                        $pull: {
                            [op.op.field]: op.op.value,                           
                        },
                    },
                    { upsert: true }
                );
            }
        }
        res.sendStatus(200);
    }));

    //
    // Uploads a new asset.
    //
    app.post("/asset", asyncErrorHandler(async (req, res) => {
        if (APP_MODE !== "readwrite") {
            res.sendStatus(403); // Forbidden in readonly mode.
            return;
        }

        const assetId = getHeader(req, "id");
        const setId = getHeader(req, "set");
        const contentType = getHeader(req, "content-type");
        const assetType = getHeader(req, "asset-type");

        console.log(`Receiving asset ${assetId} of type ${assetType} for set ${setId}.`);

        //
        // Load the entire asset into memory.
        // This is not ideal for large file, but the streaming alternative below
        // doesn't seem to work for large files anyway!
        // 
        const buffer = await new Promise<Buffer>((resolve, reject) => {
            const chunks: any[] = [];
            
            req.on('data', chunk => chunks.push(chunk));
            req.on('end', () => resolve(Buffer.concat(chunks)));
            req.on('error', reject);
        });        

        console.log(`Have buffer in memory of ${buffer.length} bytes.`);

        //
        // Sends the response before the upload is complete.
        // This prevent the client from waiting for the upload to complete (and timing out).
        //
        res.sendStatus(200);

        await storage.write(`collections/${setId}/${assetType}`, assetId, contentType, buffer);            

        console.log(`Uploaded ${buffer.length} bytes.`);

        //
        // Streaming alternative that doesn't work for large files.
        // I tried many things to get this working for a 1.4 GB video file but couldn't get it completely uploaded.
        // It always seemed to hang around the 650 MB mark.
        // Using the `writeStream` function to stream directly from the file system works ok though, it's 
        // only a problem when streaming the incoming HTTP POST request body to the cloud storage that it's an issue.
        //

        // const contentLength = parseInt(getHeader(req, "content-length"));
        // const uploadPromise = storage.writeStream(`collections/${setId}/${assetType}`, assetId, contentType, req, contentLength);

        //
        // Sends the response before the upload is complete.
        // This prevent the client from waiting for the upload to complete (and timing out).
        //
        // res.sendStatus(200);

        //
        // Waits for the upload to complete.
        // Alternate streaming code.
        //
        // await uploadPromise;
    }));

    //
    // Gets a particular asset by id.
    //
    app.get("/asset", asyncErrorHandler(async (req, res) => {
        const assetId = req.query.id as string;
        const setId = req.query.set as string;
        const assetType = req.query.type as string;
        if (!assetId || !setId || !assetType) {
            res.sendStatus(400);
            return;
        }

        const info = await storage.info(`collections/${setId}/${assetType}`, assetId);
        if (!info) {
            res.sendStatus(404);
            return;
        }

        res.writeHead(200, {
            "Content-Type": info.contentType,
        });

        storage.readStream(`collections/${setId}/${assetType}`, assetId)
            .pipe(res);
    }));

    //
    // Gets a record from the database.
    //
    app.get("/get-one", asyncErrorHandler(async (req, res) => {
        const collectionName = getValue<string>(req.query, "col");
        const recordId = getValue<string>(req.query, "id");
        const collection = db.collection(collectionName);
        const record = await collection.findOne({ _id: recordId });
        if (!record) {
            res.sendStatus(404);
            return;
        }

        res.json(record);
    }));

    //
    // Gets all records in the database.
    //
    app.get("/get-all", asyncErrorHandler(async (req, res) => {
        const setId = getValue<string>(req.query, "set");
        const collectionName = getValue<string>(req.query, "col");
        const skip = getIntQueryParam(req, "skip");
        const limit = getIntQueryParam(req, "limit");

        //TODO: black list/white list collections the client access access.
        //TODO: Ensure the user can access the set.

        //
        // TODO: bring this online later.
        //
        // const collectionMetdata = await assetDatabase.getCollectionMetadata(databaseName);
        // if (!collectionMetdata) {
        //     res.sendStatus(404);
        //     return;
        // }

        // if (req.userId === undefined 
        //     || !collectionMetdata.owners.includes(req.userId)) {
        //     // The user doesn't own this collection. They can't view the assets.
        //     res.sendStatus(403);
        //     return;
        // }

        const collection = db.collection(collectionName);
        const records = await collection.find({ setId })
            .sort({
                //
                // Reverse chronological order.
                //
                // TODO: This only makes sense for asset metadata.
                //       This doesn't make for any other database collection.
                //
                photoDate: -1, 
            })
            .skip(skip)
            .limit(limit)
            .toArray();

        res.json(records);
    }));

    //
    // Gets a record from the database based on their hash.
    //
    app.get("/check-hash", asyncErrorHandler(async (req, res) => {
        const setId = getValue<string>(req.query, "set");
        const hash = getValue<string>(req.query, "hash");
        const collection = db.collection("metadata");
        const records = await collection.find({ hash, setId }).toArray();
        res.json({
            assetIds: records.map(record => record._id),
        });
    }));    

    return app;
}
