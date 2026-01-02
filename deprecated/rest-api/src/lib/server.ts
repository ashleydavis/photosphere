import express, { Request, Response, Application } from "express";
import cors from "cors";
import { IStorage, StoragePrefixWrapper } from "storage";
import { IMediaFileDatabases, IDatabaseOp } from "defs";
import { createMediaFileDatabase, acquireWriteLock, releaseWriteLock, loadDatabase } from "api";
import { ITimestampProvider, IUuidGenerator, RandomUuidGenerator, TimestampProvider } from "utils";
import { TestUuidGenerator, TestTimestampProvider } from "node-utils";
import { BsonDatabase, IBsonCollection } from "bdb";
import type { HashCache, ScannerOptions } from "api";
import type { IAsset } from "defs";
import { streamAsset, writeAsset } from "api";

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
    openDatabase(databaseId: string): Promise<{ assetStorage: IStorage; metadataStorage: IStorage; bsonDatabase: BsonDatabase; sessionId: string; uuidGenerator: IUuidGenerator; timestampProvider: ITimestampProvider; googleApiKey: string | undefined; metadataCollection: IBsonCollection<IAsset>; scannerOptions: ScannerOptions }>;

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
    private databaseMap = new Map<string, { assetStorage: IStorage; metadataStorage: IStorage; bsonDatabase: BsonDatabase; sessionId: string; uuidGenerator: IUuidGenerator; timestampProvider: ITimestampProvider; googleApiKey: string | undefined; metadataCollection: IBsonCollection<IAsset>; scannerOptions: ScannerOptions }>();
    
    constructor(private readonly assetStorage: IStorage, private readonly googleApiKey: string | undefined) {
    }

    //
    // Opens a media file database.
    //
    async openDatabase(databaseId: string): Promise<{ assetStorage: IStorage; metadataStorage: IStorage; bsonDatabase: BsonDatabase; sessionId: string; uuidGenerator: IUuidGenerator; timestampProvider: ITimestampProvider; googleApiKey: string | undefined; metadataCollection: IBsonCollection<IAsset>; scannerOptions: ScannerOptions }> {
        let mediaFileDatabase = this.databaseMap.get(databaseId);
        if (!mediaFileDatabase) {
            const assetStorage = new StoragePrefixWrapper(this.assetStorage, databaseId);
            // Create unencrypted metadata storage (same base storage, but without encryption)
            // For now, use the same storage instance - encryption handling can be refined later
            const metadataStorage = assetStorage;
            // Create appropriate providers based on NODE_ENV
            const uuidGenerator = process.env.NODE_ENV === "testing" 
                ? new TestUuidGenerator()
                : new RandomUuidGenerator();
            const timestampProvider = process.env.NODE_ENV === "testing"
                ? new TestTimestampProvider()
                : new TimestampProvider();
                
            const sessionId = uuidGenerator.generate();
            const database = createMediaFileDatabase(
                assetStorage,
                uuidGenerator,
                timestampProvider
            );
            await loadDatabase(database.assetStorage, database.metadataCollection);
            mediaFileDatabase = {
                ...database,
                assetStorage,
                metadataStorage,
                uuidGenerator,
                timestampProvider,
                googleApiKey: this.googleApiKey,
                sessionId,
                scannerOptions: { ignorePatterns: [/\.db/] },
            };
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
        return streamAsset(mediaFileDatabase.assetStorage, assetId, assetType);
    }

    //
    // Writes an asset to the storage provider.
    //
    async write(databaseId: string, assetType: string, assetId: string, contentType: string, buffer: Buffer): Promise<void> {
        const mediaFileDatabase = await this.openDatabase(databaseId);
        await writeAsset(mediaFileDatabase.assetStorage, mediaFileDatabase.metadataStorage, mediaFileDatabase.sessionId, assetId, assetType, contentType, buffer);
    }
}

//
// Gives access to a single media file database.
//
export class SingleMediaFileDatabaseProvider implements IMediaFileDatabaseProvider {

    private mediaFileDatabase: { assetStorage: IStorage; metadataStorage: IStorage; bsonDatabase: BsonDatabase; sessionId: string; uuidGenerator: IUuidGenerator; timestampProvider: ITimestampProvider; googleApiKey: string | undefined; metadataCollection: IBsonCollection<IAsset>; scannerOptions: ScannerOptions } | undefined = undefined;
    
    constructor(private readonly assetStorage: IStorage, private readonly databaseId: string, private readonly databaseName: string, private readonly googleApiKey: string | undefined) {
    }

    //
    // Opens a media file database.
    //
    async openDatabase(_databaseId: string): Promise<{ assetStorage: IStorage; metadataStorage: IStorage; bsonDatabase: BsonDatabase; sessionId: string; uuidGenerator: IUuidGenerator; timestampProvider: ITimestampProvider; googleApiKey: string | undefined; metadataCollection: IBsonCollection<IAsset>; scannerOptions: ScannerOptions }> {
        if (this.mediaFileDatabase) {
            return this.mediaFileDatabase;
        }

        // Create unencrypted metadata storage (same base storage, but without encryption)
        // For now, use the same storage instance - encryption handling can be refined later
        const metadataStorage = this.assetStorage;
        // Create appropriate providers based on NODE_ENV
        const uuidGenerator = process.env.NODE_ENV === "testing" 
            ? new TestUuidGenerator()
            : new RandomUuidGenerator();
        const timestampProvider = process.env.NODE_ENV === "testing"
            ? new TestTimestampProvider()
            : new TimestampProvider();
            
        const sessionId = uuidGenerator.generate();
        const database = createMediaFileDatabase(
            this.assetStorage,
            uuidGenerator,
            timestampProvider
        );
        await loadDatabase(database.assetStorage, database.metadataCollection);
        this.mediaFileDatabase = {
            ...database,
            assetStorage: this.assetStorage,
            metadataStorage,
            uuidGenerator,
            timestampProvider,
            googleApiKey: this.googleApiKey,
            sessionId,
            scannerOptions: { ignorePatterns: [/\.db/] },
        };

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
        return streamAsset(this.mediaFileDatabase.assetStorage, assetId, assetType);
    }

    //
    // Writes an asset to the storage provider.
    //
    async write(databaseId: string, assetType: string, assetId: string, contentType: string, buffer: Buffer): Promise<void> {
        if (!this.mediaFileDatabase) {
            throw new Error(`Database not opened`);
        }
        await writeAsset(this.mediaFileDatabase.assetStorage, this.mediaFileDatabase.metadataStorage, this.mediaFileDatabase.sessionId, assetId, assetType, contentType, buffer);
    }            
}

export interface IServerOptions {
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
    // Reject requests to root and favicon.
    //
    app.use((req, res, next) => {

        if (req.path === "/" || req.path === "/favicon.ico") {
            res.sendStatus(404);
            return;
        }

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
                // console.log(`Handling ${req.method} ${req.path}`);
                await handler(req, res);
                // console.log(`Handled ${req.method} ${req.path}`);
            }
            catch (err: any) {
                console.error(`An error occurred handling ${req.method} ${req.path}`);
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
        const ops = getValue<IDatabaseOp[]>(req.body, "ops");
        for (const op of ops) {
            const mediaFileDatabase = await mediaFileDatabaseProvider.openDatabase(op.databaseId);
            const assetStorage = mediaFileDatabase.assetStorage;
            const sessionId = mediaFileDatabase.sessionId;
            
            //
            // Acquire write lock before database operations.
            //
            if (!await acquireWriteLock(assetStorage, sessionId)) {
                res.status(500).json({ error: `Failed to acquire write lock for database ${op.databaseId}` });
                return;
            }

            try {
                const metadataDatabase = mediaFileDatabase.bsonDatabase;            
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

        try {
            const readStream = mediaFileDatabaseProvider.readStream(databaseId, assetType, assetId);
            readStream.on('error', (err: any) => {
                if (err.code === 'ENOENT') {
                    res.sendStatus(404);
                } else {
                    console.error(`Error reading asset ${assetId}:`, err);
                    if (!res.headersSent) {
                        res.sendStatus(500);
                    }
                }
            });
            readStream.pipe(res);
        } catch (err: any) {
            if (err.code === 'ENOENT') {
                res.sendStatus(404);
            } else {
                throw err;
            }
        }
    }));

    //
    // Gets a record from the database.
    //
    app.get("/get-one", asyncErrorHandler(async (req, res) => {
        const databaseId = getValue<string>(req.query, "db");
        const collectionName = getValue<string>(req.query, "col");
        const recordId = getValue<string>(req.query, "id");
        const mediaFileDatabase = await mediaFileDatabaseProvider.openDatabase(databaseId);
        const metadataDatabase = mediaFileDatabase.bsonDatabase;
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
        const metadataDatabase = mediaFileDatabase.bsonDatabase;
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
        const metadataDatabase = mediaFileDatabase.bsonDatabase;
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
