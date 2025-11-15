import express, { Request, Response, Application } from "express";
import cors from "cors";
import { auth } from "express-oauth2-jwt-bearer";
import { IStorage, StoragePrefixWrapper } from "storage";
import { IMediaFileDatabases, IDatabaseOp } from "defs";
import { MediaFileDatabase, acquireWriteLock, releaseWriteLock } from "api";
import { ITimestampProvider, RandomUuidGenerator, TimestampProvider } from "utils";
import { TestUuidGenerator, TestTimestampProvider } from "node-utils";
import { BsonDatabase } from "bdb";

interface IUser extends IMediaFileDatabases {
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

/**
 * Provies access to media file databases.
 */
export interface IMediaFileDatabaseProvider {
    
    //
    // Gets the list of available databases.
    //
    listAssetDatabases(): Promise<{id: string, name: string}[]>;

    //
    // Opens a media file database.
    //
    openDatabase(databaseId: string): Promise<MediaFileDatabase>;

    //
    // Reads a streaming asset from the storage provider.
    //
    readStream(databaseId: string, assetType: string, assetId: string): NodeJS.ReadableStream;

    //
    // Writes an asset to the storage provider.
    //
    write(databaseId: string, assetType: string, assetId: string, contentType: string, buffer: Buffer): Promise<void>;
}

//
// Gives access to multiple media file databases.
//
export class MultipleMediaFileDatabaseProvider implements IMediaFileDatabaseProvider {

    //
    // Tracks open databases that need to be closed.
    //
    private databaseMap = new Map<string, MediaFileDatabase>();
    
    constructor(private readonly assetStorage: IStorage, private readonly metadataStorage: IStorage, private readonly googleApiKey: string | undefined) {
    }

    //
    // Opens a media file database.
    //
    async openDatabase(databaseId: string): Promise<MediaFileDatabase> {
        let mediaFileDatabase = this.databaseMap.get(databaseId);
        if (!mediaFileDatabase) {
            const assetStorage = new StoragePrefixWrapper(this.assetStorage, databaseId);
            const metadataStorage = new StoragePrefixWrapper(this.metadataStorage, `${databaseId}/.db`);
            // Create appropriate providers based on NODE_ENV
            const uuidGenerator = process.env.NODE_ENV === "testing" 
                ? new TestUuidGenerator()
                : new RandomUuidGenerator();
            const timestampProvider = process.env.NODE_ENV === "testing"
                ? new TestTimestampProvider()
                : new TimestampProvider();
                
            mediaFileDatabase = new MediaFileDatabase(
                assetStorage,
                metadataStorage,
                this.googleApiKey,
                uuidGenerator,
                timestampProvider
            );
            await mediaFileDatabase.load();
            this.databaseMap.set(databaseId, mediaFileDatabase);
            console.log(`Opened media file database in ${databaseId}.`);
        }
        return mediaFileDatabase;
    }
        
    //
    // Gets the list of available databases.
    //
    async listAssetDatabases(): Promise<{id: string, name: string}[]> {
        let next: string | undefined = undefined;
        let sets: string[] = [];
        
        do {
            const result = await this.assetStorage.listDirs("", 1000, next);
            sets.push(...result.names);
            next = result.next;
        } while (next);
        
        return sets.map(set => ({
            id: set,
            name: `${set.slice(0, 4)}-${set.slice(-4)}`,
        }));
    }

    //
    // Reads a streaming asset from the storage provider.
    //
    readStream(databaseId: string, assetType: string, assetId: string): NodeJS.ReadableStream {
        const mediaFileDatabase = this.databaseMap.get(databaseId);
        if (!mediaFileDatabase) {
            throw new Error(`Database ${databaseId} not opened`);
        }
        return mediaFileDatabase.streamAsset(assetId, assetType);
    }

    //
    // Writes an asset to the storage provider.
    //
    async write(databaseId: string, assetType: string, assetId: string, contentType: string, buffer: Buffer): Promise<void> {
        const mediaFileDatabase = await this.openDatabase(databaseId);
        await mediaFileDatabase.writeAsset(assetId, assetType, contentType, buffer);
    }
}

//
// Gives access to a single media file database.
//
export class SingleMediaFileDatabaseProvider implements IMediaFileDatabaseProvider {

    private mediaFileDatabase: MediaFileDatabase | undefined = undefined;
    
    constructor(private readonly assetStorage: IStorage, private readonly metadataStorage: IStorage, private readonly databaseId: string, private readonly databaseName: string, private readonly googleApiKey: string | undefined) {
    }

    //
    // Opens a media file database.
    //
    async openDatabase(_databaseId: string): Promise<MediaFileDatabase> {
        if (this.mediaFileDatabase) {
            return this.mediaFileDatabase;
        }

        // Create appropriate providers based on NODE_ENV
        const uuidGenerator = process.env.NODE_ENV === "testing" 
            ? new TestUuidGenerator()
            : new RandomUuidGenerator();
        const timestampProvider = process.env.NODE_ENV === "testing"
            ? new TestTimestampProvider()
            : new TimestampProvider();
            
        this.mediaFileDatabase = new MediaFileDatabase(
            this.assetStorage,
            this.metadataStorage,
            this.googleApiKey,
            uuidGenerator,
            timestampProvider
        );
        await this.mediaFileDatabase.load();

        return this.mediaFileDatabase;
    }

    //
    // Gets the list of available databases.
    //
    async listAssetDatabases(): Promise<{id: string, name: string}[]> {
        // Always return just the one database.
        return [{
            id: this.databaseId,
            name: this.databaseName,
        }];
    }

    //
    // Reads a streaming asset from the storage provider.
    //
    readStream(databaseId: string, assetType: string, assetId: string): NodeJS.ReadableStream {
        if (!this.mediaFileDatabase) {
            throw new Error(`Database not opened`);
        }
        return this.mediaFileDatabase.streamAsset(assetId, assetType);
    }

    //
    // Writes an asset to the storage provider.
    //
    async write(databaseId: string, assetType: string, assetId: string, contentType: string, buffer: Buffer): Promise<void> {
        if (!this.mediaFileDatabase) {
            throw new Error(`Database not opened`);
        }
        await this.mediaFileDatabase.writeAsset(assetId, assetType, contentType, buffer);
    }            
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
    // Custom middleware for serving static files.
    // If not provided, no static files will be served.
    //
    staticMiddleware?: express.RequestHandler;
}

//
// Starts the REST API.
//
export async function createServer(now: () => Date, mediaFileDatabaseProvider: IMediaFileDatabaseProvider, timestampProvider: ITimestampProvider, databaseStorage: IStorage | undefined, options: IServerOptions): Promise<{ app: Application }> {

    let db = databaseStorage ? new BsonDatabase({ storage: databaseStorage, uuidGenerator: new RandomUuidGenerator(), timestampProvider }) : undefined;
    
    const app = express();
    app.use(cors());

    app.get("/alive", (req, res) => {
        console.log("Server is alive.");
        res.sendStatus(200);
    });

    if (options.staticMiddleware) {
        app.use(options.staticMiddleware);
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
            });
        }
        else if (options.authType === "no-auth") {
            res.json({
                appMode: options.appMode,
                authMode: "no-auth",
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

        if (!db) {
            throw new Error("Expected database when authentication is enabled.");
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
            const user = await db!.collection<IUser>("users").getOne(userId);
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
    // Gets the Google API key for reverse geocoding.
    //
    app.get("/auth/api-keys", asyncErrorHandler(async (req, res) => {
        res.json({
            googleApiKey: options.googleApiKey,
        });
    }));

    //
    // Gets the sets the user has access to.
    //
    app.get("/dbs", asyncErrorHandler(async (req, res) => {
        if (req.user) {
            res.json(req.user);
        }
        else {
            // Get the databases from the storage provider.
            const dbs = await mediaFileDatabaseProvider.listAssetDatabases();
            res.json({ dbs });
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
            const mediaFileDatabase = await mediaFileDatabaseProvider.openDatabase(op.databaseId);
            const assetStorage = mediaFileDatabase.getAssetStorage();
            const sessionId = mediaFileDatabase.sessionId;
            
            //
            // Acquire write lock before database operations.
            //
            if (!await acquireWriteLock(assetStorage, sessionId)) {
                res.status(500).json({ error: `Failed to acquire write lock for database ${op.databaseId}` });
                return;
            }

            try {
                const metadataDatabase = mediaFileDatabase.getMetadataDatabase();            
                const recordCollection = metadataDatabase.collection(op.collectionName);
                
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
            finally {
                //
                // Release write lock after database operations.
                //
                await releaseWriteLock(assetStorage);
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
        const databaseId = getHeader(req, "db");
        const contentType = getHeader(req, "content-type");
        const assetType = getHeader(req, "asset-type");

        console.log(`Receiving asset ${assetId} of type ${assetType} for set ${databaseId}.`);

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

        await mediaFileDatabaseProvider.write(databaseId, assetType, assetId, contentType, buffer);
        
        console.log(`Uploaded ${buffer.length} bytes to ${assetType}/${assetId}.`);

        //
        // Streaming alternative that doesn't work for large files.
        // I tried many things to get this working for a 1.4 GB video file but couldn't get it completely uploaded.
        // It always seemed to hang around the 650 MB mark.
        // Using the `writeStream` function to stream directly from the file system works ok though, it's 
        // only a problem when streaming the incoming HTTP POST request body to the cloud storage that it's an issue.
        //

        // const contentLength = parseInt(getHeader(req, "content-length"));
        // const uploadPromise = storage.writeStream(`collections/${databaseId}/${assetType}`, assetId, contentType, req, contentLength);

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
        const databaseId = req.query.db as string;
        const assetType = req.query.type as string;
        if (!assetId || !databaseId || !assetType) {
            res.sendStatus(400);
            return;
        }

        const readStream = mediaFileDatabaseProvider.readStream(databaseId, assetType, assetId);
        readStream.pipe(res);
    }));

    //
    // Gets a record from the database.
    //
    app.get("/get-one", asyncErrorHandler(async (req, res) => {
        const databaseId = getValue<string>(req.query, "db");
        const collectionName = getValue<string>(req.query, "col");
        const recordId = getValue<string>(req.query, "id");
        const mediaFileDatabase = await mediaFileDatabaseProvider.openDatabase(databaseId);
        const metadataDatabase = mediaFileDatabase.getMetadataDatabase();
        const collection = metadataDatabase.collection(collectionName);
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
        const databaseId = getValue<string>(req.query, "db");
        const collectionName = getValue<string>(req.query, "col");
        const next = req.query.next as string | undefined;

        const mediaFileDatabase = await mediaFileDatabaseProvider.openDatabase(databaseId);
        const metadataDatabase = mediaFileDatabase.getMetadataDatabase();
        const collection = metadataDatabase.collection(collectionName);
        const result = await collection.getSorted("photoDate", "desc", next);
        res.json({
            records: result.records,
            next: result.nextPageId,
        });
    }));

    //
    // Gets a record from the database based on their hash.
    //
    app.get("/check-hash", asyncErrorHandler(async (req, res) => {
        const databaseId = getValue<string>(req.query, "db");
        const hash = getValue<string>(req.query, "hash");
        const mediaFileDatabase = await mediaFileDatabaseProvider.openDatabase(databaseId);
        const metadataDatabase = mediaFileDatabase.getMetadataDatabase();
        const metadataCollection = metadataDatabase.collection("metadata");
        await metadataCollection.ensureSortIndex("hash", "asc", "string");
        const records = await metadataCollection.findByIndex("hash", hash);
        const matchingRecordIds = records.map(record => record._id);
        res.json({
            assetIds: matchingRecordIds,
        });
    }));    

    return {
        app,
    };
}
