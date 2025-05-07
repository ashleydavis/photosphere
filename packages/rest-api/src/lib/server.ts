import express, { Request, Response } from "express";
import cors from "cors";
import { auth } from "express-oauth2-jwt-bearer";
import { BsonDatabase, IBsonDatabase, IStorage, pathJoin, StoragePrefixWrapper } from "storage";
import { ISets, IDatabaseOp } from "defs";

interface IUser extends ISets {
    _id: string;
}

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

export interface IAuth0Options {
    clientId: string;
    audience: string;
    domain: string;
    redirectUrl: string;
}

export interface IServerOptions {
    //
    // Sets the mode of the server.
    //
    appMode: string; // "readonly" | "readwrite"

    //
    // Sets the type of authentication to use.
    //
    authType: string; // "auth0" | "no-auth"

    //
    // Authentication options for auth0.
    //
    auth0?: IAuth0Options;

    //
    // The Google API key for reverse geocoding, if provided.
    //
    googleApiKey?: string;

    //
    // The path to the frontend static files.
    //
    frontendStaticPath?: string;
}

//
// Starts the REST API.
//
export async function createServer(now: () => Date, assetStorage: IStorage, databaseStorage: IStorage, options: IServerOptions) {

    const db = new BsonDatabase({ storage: databaseStorage });

    const bsonDatabaseMap = new Map<string, IBsonDatabase>();

    //
    // Opens a database for a particular set.
    //
    function openDatabase(setId: string): IBsonDatabase {
        let bsonDatabase = bsonDatabaseMap.get(setId);
        if (!bsonDatabase) {
            const directory = `${setId}/metadata`;
            bsonDatabase = new BsonDatabase({
                storage: new StoragePrefixWrapper(pathJoin(assetStorage.location, directory), assetStorage, directory),
            });
            bsonDatabaseMap.set(setId, bsonDatabase);
            console.log(`Opened BSON database in ${directory}.`);
        }
        return bsonDatabase;

    }

    const app = express();
    app.use(cors());

    app.get("/alive", (req, res) => {
        console.log("Server is alive.");
        res.sendStatus(200);
    });

    if (options.frontendStaticPath) {
        app.use(express.static(options.frontendStaticPath));
    }

    //
    // Configures authentication in the frontend.
    //
    app.get("/auth/config", (req, res) => {
        if (options.authType === "auth0") {
            if (!options.auth0) {
                console.error("Expected auth0 options");
                res.sendStatus(500);
                return;
            }

            res.json({
                appMode: options.appMode,
                authMode: "auth0",
                auth0: {
                    domain: options.auth0.domain,
                    clientId: options.auth0.clientId,
                    audience: options.auth0.audience,
                    redirectUrl: options.auth0.redirectUrl,
                },
                goopleApiKey: options.googleApiKey,
            });
        }
        else if (options.authType === "no-auth") {
            res.json({
                appMode: options.appMode,
                authMode: "no-auth",
                goopleApiKey: options.googleApiKey,
            });
        }
        else {
            console.error(`Unknown auth type: ${options.authType}`);
            res.status(500);
        }
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

    if (options.authType === "auth0") {
        if (!options.auth0) {
            throw new Error("Expected auth0 options");
        }
        
        const checkJwt = auth({
            audience: options.auth0.audience,
            issuerBaseURL: options.auth0.domain,
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

                let numPadding = 32 - userId.length;
                if (numPadding < 0) {
                    console.log(`User ID is too long: ${userId}`);
                    res.sendStatus(401);
                    return;
                }

                userId += '0'.repeat(numPadding); // Pad the user id to 32 characters to match the database.
            }
            const user = await db.collection<IUser>("users").getOne(userId);
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
    else if (options.authType === "no-auth") {
        console.warn("No authentication enabled.");
    }
    else {
        throw new Error(`Unknown auth type: ${options.authType}`);
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
                // console.log(`Handling ${req.method} ${req.path}`);
                await handler(req, res);
                // console.log(`Handled ${req.method} ${req.path}`);
            }
            catch (err: any) {
                console.error(`An error occured handling ${req.method} ${req.path}`);
                console.error(err.stack);
                res.sendStatus(500);
            }
        };
    }

    //
    // Gets the sets the user has access to.
    //
    app.get("/sets", asyncErrorHandler(async (req, res) => {
        if (req.user) {
            res.json(req.user);
        }
        else {
            //
            // Read the sets from storage.
            //
            let next: string | undefined = undefined;
            let sets: string[] = [];

            do {
                const result = await assetStorage.listDirs("", 1000, next);
                sets.push(...result.names);
                next = result.next;

            } while (next);

            res.json({
                sets: sets.map(set => ({
                    id: set,
                    name: `${set.slice(0, 4)}-${set.slice(-4)}`,
                })),
            });
        }
    }));
    
    //
    // Applies a set of operations to the asset database.
    //
    app.post("/operations", express.json(), asyncErrorHandler(async (req, res) => {
        if (options.appMode !== "readwrite") {
            res.sendStatus(403); // Forbidden in readonly mode.
            return;
        }

        const ops = getValue<IDatabaseOp[]>(req.body, "ops");
        for (const op of ops) {
            const database = openDatabase(op.setId);
            const recordCollection = database.collection(op.collectionName);
            
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

                await recordCollection.updateOne(op.recordId, fields, { upsert: true });
            }
            else if (op.op.type === "push") {
                const record = await recordCollection.getOne(op.recordId); //TODO: Should the db take care of this?
                const array = record?.[op.op.field] || [];
                array.push(op.op.value);
                await recordCollection.updateOne(op.recordId, { [op.op.field]: array }, { upsert: true });
            }
            else if (op.op.type === "pull") {
                const record = await recordCollection.getOne(op.recordId); //TODO: Should the db take care of this?
                const array = record?.[op.op.field] || [];
                const value = op.op.value;
                const updatedArray = array.filter((item: any) => item !== value);
                await recordCollection.updateOne(op.recordId, { [op.op.field]: updatedArray }, { upsert: true });
            }
        }
        res.sendStatus(200);
    }));

    //
    // Uploads a new asset.
    //
    app.post("/asset", asyncErrorHandler(async (req, res) => {
        if (options.appMode !== "readwrite") {
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

        await assetStorage.write(`${setId}/${assetType}/${assetId}`, contentType, buffer);            

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

        const info = await assetStorage.info(`${setId}/${assetType}/${assetId}`);
        if (!info) {
            res.sendStatus(404);
            return;
        }

        res.writeHead(200, {
            "Content-Type": info.contentType,
        });

        assetStorage.readStream(`${setId}/${assetType}/${assetId}`)
            .pipe(res);
    }));

    //
    // Gets a record from the database.
    //
    app.get("/get-one", asyncErrorHandler(async (req, res) => {
        const setId = getValue<string>(req.query, "set");
        const collectionName = getValue<string>(req.query, "col");
        const recordId = getValue<string>(req.query, "id");
        const database = openDatabase(setId);
        const collection = database.collection(collectionName);
        const record = await collection.getOne(recordId);
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
        const next = req.query.next as string | undefined;
        const nextPage = next ? parseInt(next) : 1;

        const database = openDatabase(setId);
        const collection = database.collection(collectionName);
        const result = await collection.getSorted("photoDate", { 
            direction: "desc", //todo: The field and direction should be passed through the API.
            page: nextPage,
            pageSize: 1000, //todo: Be good to tie this in directly to the continuation token.            
        }); 
        res.json({
            records: result.records,
            next: (nextPage + 1).toString(),
        });
    }));

    //
    // Gets a record from the database based on their hash.
    //
    app.get("/check-hash", asyncErrorHandler(async (req, res) => {
        const setId = getValue<string>(req.query, "set");
        const hash = getValue<string>(req.query, "hash");
        const db = openDatabase(setId);
        const metadataCollection = db.collection("metadata");
        await metadataCollection.ensureIndex("hash");
        const records = await metadataCollection.findByIndex("hash", hash);
        const matchingRecordIds = records.map(record => record._id);
        res.json({
            assetIds: matchingRecordIds,
        });
    }));    

    return {
        app,
        close: async () => {
            console.log("Shutting down server.");

            for (const bsonDatabase of bsonDatabaseMap.values()) {
                await bsonDatabase.close();
            }
    
            bsonDatabaseMap.clear();            
        },
    };
}
