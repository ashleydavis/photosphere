import express, { Request, Response } from "express";
import cors from "cors";
import { auth } from "express-oauth2-jwt-bearer";
import { Db } from "mongodb";
import { IStorage } from "storage";
import { IUser, IDatabaseOp } from "defs";
import { uuid } from "./lib/uuid";

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

    const isProduction = process.env.NODE_ENV !== "development" && process.env.NODE_ENV !== "test";
    if (isProduction) {
        
        const checkJwt = auth({
            audience: process.env.AUTH0_AUDIENCE as string,
            issuerBaseURL: process.env.AUTH0_BASE_URL as string,
            tokenSigningAlg: 'RS256'        
        });

        //
        // Authenticates a JWT token.
        //
        app.use(checkJwt);
    }
    else {
        //
        // Mocks a JWT token.
        //
        app.use((req, res, next) => {
            req.auth = { 
                payload: { 
                    sub: "test-user", // Test user.
                } 
            } as any;
            
            next();
        });
    }

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
    // Gets the user's metadata.
    //
    app.get("/user", asyncErrorHandler(async (req, res) => {
        res.json(req.user);
    }));
    
    //
    // Applies a set of operations to the asset database.
    //
    app.post("/operations", express.json(), asyncErrorHandler(async (req, res) => {
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
        const assetId = getHeader(req, "id");
        const setId = getHeader(req, "set");
        const contentType = getHeader(req, "content-type");
        const assetType = getHeader(req, "asset-type");
        await storage.writeStream(`collections/${setId}/${assetType}`, assetId, contentType, req);
        res.sendStatus(200);
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
