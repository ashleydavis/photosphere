import express, { Request, Response } from "express";
import cors from "cors";
import { IAsset } from "./lib/asset";
import dayjs from "dayjs";
import { IAssetDatabase } from "./services/asset-database";
import { auth } from "express-oauth2-jwt-bearer";
import { IDatabaseCollection } from "./services/database-collection";
import { IUser } from "./lib/user";

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
export async function createServer(now: () => Date, assetDatabase: IAssetDatabase, userDatabase: IDatabaseCollection<IUser>) {

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

        // Check if the token exists in the query parameters.
        if (!req.headers.authorization && req.query && req.query.tok) {
            // Add the token to the Authorization header.
            req.headers.authorization = `Bearer ${req.query.tok}`;
        }
        
        next();
    });

    if (process.env.NODE_ENV !== "development" && process.env.NODE_ENV !== "test") {
        
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
        const user = await userDatabase.getOne(`users`, userId);
        if (!user) {
            console.log(`User not found: ${userId}`);
            res.sendStatus(401);
            return;
        }

        req.userId = userId;
        req.user = user;
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
    // TODO: Deprecated in favor of database options.
    //
    // Uploads metadata for an asset and allocates a new asset id.
    //
    app.post("/metadata", express.json(), asyncErrorHandler(async (req, res) => {

        const metadata = req.body;
        const collectionId = getValue<string>(metadata, "col");
        const assetId = getValue<string>(req.body, "id");
        const fileName = getValue<string>(metadata, "fileName");
        const width = getValue<number>(metadata, "width");
        const height = getValue<number>(metadata, "height");
        const hash = getValue<string>(metadata, "hash");
        const fileDate = dayjs(getValue<string>(metadata, "fileDate")).toDate();
        const labels = metadata.labels || [];
        const photoDate = metadata.photoDate ? dayjs(metadata.photoDate).toDate() : undefined;
        const uploadDate = now();
        const sortDate = photoDate || fileDate || uploadDate;

        const newAsset: IAsset = {
            _id: assetId,
            origFileName: fileName,
            width: width,
            height: height,
            hash: hash,
            fileDate: fileDate,
            photoDate: photoDate,
            sortDate: sortDate,
            uploadDate: uploadDate,
            labels: labels,
        };

        if (metadata.location) {
            newAsset.location = metadata.location; 
        }

        if (metadata.properties) {
            newAsset.properties = metadata.properties;
        }

        await assetDatabase.addMetadata(collectionId, assetId, hash, newAsset);

        res.json({
            assetId: assetId,
        });
    }));

    //
    // TODO: Deprecated in favor of database options.
    // 
    // Applies a partial metdata update to an asset.
    //
    app.patch("/metadata", express.json(), asyncErrorHandler(async (req, res) => {
        const collectionId = getValue<string>(req.body, "col");
        const assetId = getValue<string>(req.body, "id");
        const update: Partial<IAsset> = req.body.update;
        await assetDatabase.updateMetadata(collectionId, assetId, update);
        res.sendStatus(200);
    }));

    //
    // Applies a set of operations to the asset database.
    //
    app.put("/metadata", express.json(), asyncErrorHandler(async (req, res) => {
        const { dbOps } = req.body;
        await assetDatabase.applyOperations(dbOps);
        res.sendStatus(200);
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

        const metadata = await assetDatabase.getMetadata(collectionId, assetId);
        if (!metadata) {
            res.sendStatus(404);
            return;
        }

        res.json(metadata);
    }));

    //
    // Uploads a new asset.
    //
    app.post("/asset", asyncErrorHandler(async (req, res) => {
        const assetId = getHeader(req, "id");
        const collectionId = getHeader(req, "col");
        const contentType = getHeader(req, "content-type");
        await assetDatabase.uploadOriginal(collectionId, assetId, contentType, req);
        res.sendStatus(200);
    })); 

    //
    // Gets a particular asset by id.
    //
    app.get("/asset", asyncErrorHandler(async (req, res) => {

        const assetId = req.query.id as string;
        const collectionId = req.query.col as string;
        if (!assetId || !collectionId) {
            res.sendStatus(400);
            return;
        }

        const assetStream = await assetDatabase.streamOriginal(collectionId, assetId);
        if (!assetStream) {
            res.sendStatus(404);
            return;
        }

        res.writeHead(200, {
            "Content-Type": assetStream.contentType,
        });

        assetStream.stream.pipe(res);
    }));

    //
    // Uploads a thumbnail for a particular asset.
    //
    app.post("/thumb", asyncErrorHandler(async (req, res) => {
        const assetId = getHeader(req, "id");
        const collectionId = getHeader(req, "col");
        const contentType = getHeader(req, "content-type");
        await assetDatabase.uploadThumbnail(collectionId, assetId, contentType, req);
        res.sendStatus(200);
    }));

    //
    // Gets the thumb for an asset by id.
    //
    app.get("/thumb", asyncErrorHandler(async (req, res) => {

        const assetId = req.query.id as string;
        const collectionId = req.query.col as string;
        if (!assetId || !collectionId) {
            res.sendStatus(400);
            return;
        }

        const assetStream = await assetDatabase.streamThumbnail(collectionId, assetId);
        if (!assetStream) {
            res.sendStatus(404);
            return;
        }

        res.writeHead(200, {
            "Content-Type": assetStream.contentType,
        });

        assetStream.stream.pipe(res);
    }));

    //
    // Uploads a display version for a particular asset.
    //
    app.post("/display", asyncErrorHandler(async (req, res) => {
        const assetId = getHeader(req, "id");
        const collectionId = getHeader(req, "col");
        const contentType = getHeader(req, "content-type");
        await assetDatabase.uploadDisplay(collectionId, assetId, contentType, req);
        res.sendStatus(200);
    }));

    //
    // Gets the display version for an asset by id.
    //
    app.get("/display", asyncErrorHandler(async (req, res) => {

        const assetId = req.query.id as string;
        const collectionId = req.query.col as string;
        if (!assetId || !collectionId) {
            res.sendStatus(400);
            return;
        }

        const assetStream = await assetDatabase.streamDisplay(collectionId, assetId);
        if (!assetStream) {
            res.sendStatus(404);
            return;
        }

        res.writeHead(200, {
            "Content-Type": assetStream.contentType,
        });

        assetStream.stream.pipe(res);
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
        const assetId = await assetDatabase.checkAsset(collectionId, hash);
        if (assetId) {
            // The asset exists.
            res.json({ assetId: assetId });
        }
        else {
            // The asset doesn't exist.
            res.json({ assetId: undefined });
        }
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

        const result = await assetDatabase.getAssets(collectionId, next);
        res.json({
            assets: result.assets,
            next: result.next,
        });    
    }));

    return app;
}
