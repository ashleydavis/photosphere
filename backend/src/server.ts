import express, { Request, Response } from "express";
import cors from "cors";
import { auth } from "express-oauth2-jwt-bearer";
import { IUser } from "./lib/user";
import { IDatabaseCollection, IDatabaseOp, IDatabaseOpRecord, IDatabases, IStorage, applyOperationToDb, getJournal } from "database";
import { IAsset } from "./lib/asset";

declare global {
    namespace Express {
        interface Request {
            userId?: string;
            user?: IUser;
        }
    }
}

//
// Starts the REST API.
//
export async function createServer(now: () => Date, databases: IDatabases, userCollection: IDatabaseCollection<IUser>, storage: IStorage) {

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
        const user = await userCollection.getOne(userId);
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
    app.get("/user", asyncErrorHandler(async (req, res) => { //todo: test me .http and jest
        res.json(req.user);
    }));

    //
    // Gets the metadata for an asset by id.
    //
    app.get("/metadata", asyncErrorHandler(async (req, res) => {

        const assetId = req.query.id as string;
        const collectionId = req.query.col as string;
        if (!assetId || !collectionId) {
            res.sendStatus(400);
            return;
        }

        const assetCollection = await databases.database(collectionId);
        const metadataCollection = assetCollection.collection<IAsset>("metadata");
        const metadata = await metadataCollection.getOne(assetId);
        if (!metadata) {
            res.sendStatus(404);
            return;
        }

        res.json(metadata);
    }));

    //
    // Applies a set of operations to the asset database.
    //
    app.post("/operations", express.json(), asyncErrorHandler(async (req, res) => {
        const ops = getValue<IDatabaseOp[]>(req.body, "ops");
        const clientId = getValue<string>(req.body, "clientId");
        for (const op of ops) {
            const assetCollection = await databases.database(op.databaseName);
            await applyOperationToDb(assetCollection, op, clientId);
        }
        res.sendStatus(200);
    }));

    //
    // Gets the journal of operations that have been applied to the database.
    //
    app.post("/journal", express.json(), asyncErrorHandler(async (req, res) => {
        const collectionId = getValue<string>(req.body, "collectionId");
        const clientId = getValue<string>(req.body, "clientId");
        const lastUpdateId = req.body.lastUpdateId;
        const assetCollection = await databases.database(collectionId);
        const result = await getJournal(assetCollection, clientId, lastUpdateId);
        res.json(result);
    }));

    //
    // Retreives the latest update id for a collection.
    //
    app.get("/latest-update-id", asyncErrorHandler(async (req, res) => {
        const collectionId = getHeader(req, "col");
        const assetCollection = await databases.database(collectionId);
        const journalCollection = assetCollection.collection<IDatabaseOpRecord>("journal");
        const journalIdsPage = await journalCollection.listAll(1);
        if (journalIdsPage.records.length === 0) {
            res.json({
                latestUpdateId: undefined,
            });
            return
        }

        const latestUpdateId = journalIdsPage.records[0];
        res.json({
            latestUpdateId: latestUpdateId,
        });
    }));

    //
    // Uploads a new asset.
    //
    app.post("/asset", asyncErrorHandler(async (req, res) => {
        const assetId = getHeader(req, "id");
        const collectionId = getHeader(req, "col");
        const contentType = getHeader(req, "content-type");
        const assetType = getHeader(req, "asset-type");
        await storage.writeStream(`collections/${collectionId}/${assetType}`, assetId, contentType, req);
        res.sendStatus(200);
    }));

    //
    // Gets a particular asset by id.
    //
    app.get("/asset", asyncErrorHandler(async (req, res) => {

        const assetId = req.query.id as string;
        const collectionId = req.query.col as string;
        const assetType = req.query.type as string;
        if (!assetId || !collectionId || !assetType) {
            res.sendStatus(400);
            return;
        }

        const info = await storage.info(`collections/${collectionId}/${assetType}`, assetId);
        if (!info) {
            res.sendStatus(404);
            return;
        }

        res.writeHead(200, {
            "Content-Type": info.contentType,
        });

        storage.readStream(`collections/${collectionId}/${assetType}`, assetId)
            .pipe(res);
    }));

    //
    // Checks if an asset has already been upload by its hash.
    //
    app.get("/check-asset", asyncErrorHandler(async (req, res) => {

        const hash = req.query.hash as string;
        const collectionId = req.query.col as string;
        if (!hash || !collectionId) {
            res.sendStatus(400);
            return;
        }

        // Read the hash map.
        const assetCollection = await databases.database(collectionId);
        const hashesCollection = assetCollection.collection<string[]>("hashes");
        const assetIds =  await hashesCollection.getOne(hash);
        if (!assetIds || assetIds.length === 0) {
            res.json({ assetId: undefined });
            return;
        }

        const assetId = assetIds[0]; //todo: This should return the array of assetIds.

        // The asset exists.
        res.json({ assetId: assetId });
    }));

    //
    // Gets a paginated list of all assets.
    //
    app.get("/assets", asyncErrorHandler(async (req, res) => {
        const next = req.query.next as string;
        const collectionId = req.query.col as string;
        if (!collectionId) {
            res.sendStatus(400);
            return;
        }

        //
        // TODO: bring this online later.
        //
        // const collectionMetdata = await assetDatabase.getCollectionMetadata(collectionId);
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

        const assetCollection = await databases.database(collectionId);
        const metadataCollection = assetCollection.collection<IAsset>("metadata");
        const result = await metadataCollection.getAll(1000, next);
        res.json({
            assets: result.records,
            next: result.next,
        });
    }));

    return app;
}
