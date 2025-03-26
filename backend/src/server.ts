import express, { Request, Response } from "express";
import cors from "cors";
import { auth } from "express-oauth2-jwt-bearer";
import { BsonDatabase, IBsonDatabase, IStorage } from "storage";
import { IUser, IDatabaseOp } from "defs";
import { registerTerminationCallback } from "./lib/termination";
import path from "path";

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
    if (AUTH_TYPE === "auth0") {
        if (!process.env.AUTH0_AUDIENCE) {
            throw new Error("Expected AUTH0_AUDIENCE environment variable");
        }

        if (!process.env.AUTH0_BASE_URL) {
            throw new Error("Expected AUTH0_BASE_URL environment variable");
        }
    }
}

//
// Starts the REST API.
//
export async function createServer(now: () => Date, assetStorage: IStorage, databaseStorage: IStorage) {

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
                storage: assetStorage,
                directory,
            });
            bsonDatabaseMap.set(setId, bsonDatabase);
            console.log(`Opened BSON database in ${directory}.`);
        }
        return bsonDatabase;

    }

    registerTerminationCallback(async () => {
        console.log("Shutting down server.");
        for (const bsonDatabase of bsonDatabaseMap.values()) {
            await bsonDatabase.shutdown();
        }

        bsonDatabaseMap.clear();
    });

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
    else if (process.env.AUTH_TYPE === "no-auth") {
        //
        //
        // Attaches user information to the request.
        //
        app.use(async (req, res, next) => {
            req.userId = '8632edb0-8a4d-41d2-8648-f734bea0be4b'; //TOOD: This could be set by env var.

            const user = await db.collection<IUser>("users").getOne(req.userId);
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

        const database = openDatabase(setId);
        const collection = database.collection(collectionName);
        const records = await collection.getAll(skip, limit); //TODO: Ideally the output here would be sorted by date or place.
        res.json(records);
    }));

    /**
     * Loads file hashes from serialized file, reconstructing full FileHash objects
     * TODO: This should be delegated to the asset storage system, which should have a way to load hashes.
     */
    async function loadHashes(setId: string): Promise<Map<string, string[]>> {
        const hashMap = new Map<string, string[]>();
        const hashesData = await assetStorage.read(`${setId}/.db/hashes.dat`);
        if (!hashesData) {
            return hashMap;
        }

        let offset = 0;
        
        // Read the segment table first
        const segmentTableSize = hashesData.readUInt32LE(offset);
        offset += 4;
        
        // Read all segments in the segment table
        const segmentTable: string[] = [];
        for (let i = 0; i < segmentTableSize; i++) {
            const segmentLength = hashesData.readUInt16LE(offset);
            offset += 2;
            const segment = hashesData.slice(offset, offset + segmentLength).toString('utf8');
            offset += segmentLength;
            segmentTable.push(segment);
        }
        
        // Read path list
        const pathsCount = hashesData.readUInt32LE(offset);
        offset += 4;
        
        // Read all paths (directory segments + filename)
        const pathsList: string[] = [];
        for (let i = 0; i < pathsCount; i++) {
            // Read number of directory segments
            const dirSegmentsCount = hashesData.readUInt8(offset);
            offset += 1;
            
            // Read directory segments
            const dirSegments: string[] = [];
            for (let j = 0; j < dirSegmentsCount; j++) {
                const segmentIndex = hashesData.readUInt16LE(offset);
                offset += 2;
                
                if (segmentIndex >= segmentTable.length) {
                    throw new Error(`Invalid segment index: ${segmentIndex}`);
                }
                
                dirSegments.push(segmentTable[segmentIndex]);
            }
            
            // Read filename directly
            const fileNameLength = hashesData.readUInt16LE(offset);
            offset += 2;
            const fileName = hashesData.slice(offset, offset + fileNameLength).toString('utf8');
            offset += fileNameLength;
            
            // Combine directory parts and filename into a full path
            let fullPath: string;
            if (dirSegments.length > 0) {
                fullPath = dirSegments.join('/') + '/' + fileName;
            } else {
                fullPath = fileName;
            }
            
            pathsList.push(fullPath);
        }
        
        // Now read the hash count
        const hashCount = hashesData.readUInt32LE(offset);
        offset += 4;

        for (let i = 0; i < hashCount; i++) {
            // Read index (4 bytes)
            const index = hashesData.readUInt32LE(offset);
            offset += 4;

            // Read path index (2 bytes) - index into paths list
            const pathIndex = hashesData.readUInt16LE(offset);
            offset += 2;
            
            // Get the file path from the paths list
            if (pathIndex >= pathsList.length) {
                throw new Error(`Invalid path index: ${pathIndex}`);
            }
            const filePath = pathsList[pathIndex];

            // Read hash
            const hash = hashesData.slice(offset, offset + 32);
            offset += 32;

            // Read file size
            let size = 0;
            if (offset + 8 <= hashesData.length) {
                // Read size as 64-bit number
                size = Number(hashesData.readBigUInt64LE(offset));
                offset += 8;
            }

            // Add to hash cache (we keep them sorted when writing, reading from the same order preserves that)
            const hashStr = hash.toString('hex');
            let filePaths = hashMap.get(hashStr);
            if (!filePaths) {
                filePaths = [];
                hashMap.set(hashStr, filePaths);
            }
            filePaths.push(path.basename(filePath));
        }

        return hashMap;
    }    

    //
    // Gets a record from the database based on their hash.
    //
    app.get("/check-hash", asyncErrorHandler(async (req, res) => {
        const setId = getValue<string>(req.query, "set");
        const hash = getValue<string>(req.query, "hash");
        const hashMap = await loadHashes(setId); //todo: Consider caching this per set.
        const matchingReocrdIds = hashMap.get(hash) || [];
        res.json({
            assetIds: matchingReocrdIds,
        });
    }));    

    return app;
}
