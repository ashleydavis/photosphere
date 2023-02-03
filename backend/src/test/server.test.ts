import { createServer } from "../server";
import request from "supertest";
import * as fs from "fs-extra";
import { ObjectId } from "mongodb";
import { executionAsyncId } from "async_hooks";

describe("photosphere backend", () => {

    //
    // Initialises the server for testing.
    //
    async function initServer() {

        //
        // Remove local assets from other test runs.
        //
        await fs.remove("./uploads");
        await fs.ensureDir("./uploads");

        const mockCollection: any = {
            find() {
                return {
                    skip() {
                        return {
                            limit() {
                                return {
                                    toArray() {
                                        return [];
                                    }
                                };
                            }
                        };
                    }
                };
            },
        };
        const mockDb: any = {
            collection() {
                return mockCollection;
            },
        };

        const app = await createServer(mockDb);
        return { 
            app, 
            mockCollection, 
            mockDb,
        };
    }

    //
    // Get list of assets uploaded.
    //
    async function getUploads() {
        const exists = await fs.exists("./uploads");
        if (exists) {
            return await fs.readdir("./uploads");
        }
        else {
            return [];
        }
    }

    test("no assets", async () => {

        const { app } = await initServer();
        const response = await request(app).get("/assets?skip=0&limit=100");
        
        expect(response.statusCode).toBe(200);
        expect(response.body).toEqual({ 
            assets: [],
        });
    });

    test("upload asset", async () => {

        const { app, mockCollection } = await initServer();

        //
        // Check we are starting with zero files.
        //
        const origFiles = await getUploads();
        expect(origFiles.length).toBe(0);

        mockCollection.insertOne = jest.fn();

        const metadata = {
            fileName: "a-test-file.jpg",
            contentType: "image/jpeg",
            thumbContentType: "image/png",
            width: 256,
            height: 1024,
            hash: "1234",
            location: "Somewhere",
            properties: {
                "a": "property",
            },
        };

        const response = await request(app)
            .post("/asset")
            .set("metadata", JSON.stringify(metadata))
            .set("thumbnail", "iVBORw0KGgoAAAANSUhEUgAAAAoAAAAKCAIAAAACUFjqAAAAXUlEQVR4nL3MoRHAIAxG4bQDRJGLYP9tmAEwiQHFAPy4Co5W9tnv7l0pJXrv/rCfuPdeSiGiWmtrbecQAoCc85xTRA5zVR1jqOphDsDMYoxmBmBnd2dmEWFmd394AV5LK0bYIwU3AAAAAElFTkSuQmCC")
            .send(fs.readFileSync("./test/test-assets/1.jpeg"));

        const assetId = response.body.assetId;

        expect(response.statusCode).toBe(200);
        expect(assetId).toBeDefined();
        expect(assetId.length).toBeGreaterThan(0);

        expect(mockCollection.insertOne).toHaveBeenCalledTimes(1);
        expect(mockCollection.insertOne).toHaveBeenCalledWith({
            _id: new ObjectId(assetId),
            origFileName: metadata.fileName,
            contentType: metadata.contentType,
            thumbContentType: metadata.thumbContentType,
            width: metadata.width,
            height: metadata.height,
            hash: metadata.hash,
            location: metadata.location,
            properties: metadata.properties,
        });

        const uploadedFiles = await getUploads();
        expect(uploadedFiles).toEqual([
            assetId,
        ]);
    });

    //
    // Uploads an asset with one of the required headers missing.
    //
    async function uploadAssetWithMissingMetadata(metadata: any, missingField: string) {

        const { app } = await initServer();

        const req = request(app).post("/asset");

        const augumented = Object.assign({}, metadata);
        delete augumented[missingField];

        const response = await req
            .set("metadata", JSON.stringify(metadata))
            .set("thumbnail", "iVBORw0KGgoAAAANSUhEUgAAAAoAAAAKCAIAAAACUFjqAAAAXUlEQVR4nL3MoRHAIAxG4bQDRJGLYP9tmAEwiQHFAPy4Co5W9tnv7l0pJXrv/rCfuPdeSiGiWmtrbecQAoCc85xTRA5zVR1jqOphDsDMYoxmBmBnd2dmEWFmd394AV5LK0bYIwU3AAAAAElFTkSuQmCC")
            .send(fs.readFileSync("./test/test-assets/1.jpeg"));
    
        expect(response.statusCode).toBe(500);
    }
    
    test("upload asset with missing headers", async () => {

        const metadata = {
            "fileName": "a-test-file.jpg",
            "contentType": "image/jpeg",
            "thumbContentType": "image/png",
            "width": 256,
            "height": 1024,
            "hash": "1234",
        };

        await uploadAssetWithMissingMetadata(metadata, "fileName");
        await uploadAssetWithMissingMetadata(metadata, "contentType");
        await uploadAssetWithMissingMetadata(metadata, "thumbContentType");
        await uploadAssetWithMissingMetadata(metadata, "width");
        await uploadAssetWithMissingMetadata(metadata, "height");
        await uploadAssetWithMissingMetadata(metadata, "hash");
    });

    //
    // Uploads an asset with the specified headers.
    //
    async function uploadAsset(headers: { [index: string]: string; }) {

        const { app, mockCollection } = await initServer();

        mockCollection.insertOne = () => {};

        const req = request(app).post("/asset");

        for (const [header, value] of Object.entries(headers)) {
            req.set(header, value);
        }
    
        return await req
            .send(fs.readFileSync("./test/test-assets/1.jpeg"));
    }
    
    test("upload asset with bad width", async () => {

        const headers = {
            "file-name": "a-test-file.jpg",
            "content-type": "image/jpg",
            "width": "---",
            "height": "1024",
            "hash": "1234",
        };

        const response = await uploadAsset(headers);
        expect(response.statusCode).toBe(500);
    });

    test("upload asset with bad height", async () => {

        const headers = {
            "file-name": "a-test-file.jpg",
            "content-type": "image/jpg",
            "width": "256",
            "height": "---",
            "hash": "1234",
        };

        const response = await uploadAsset(headers);
        expect(response.statusCode).toBe(500);
    });

    test("get existing asset", async () => {

        const assetId = new ObjectId();
        const { app, mockCollection } = await initServer();

        // Generate the file into the uploads directory.
        await fs.writeFile(`./uploads/${assetId}`, "ABCD");

        const mockAsset: any = {
            contentType: "image/jpeg",
        };
        mockCollection.findOne = (query: any) => {
            expect(query._id).toEqual(assetId);
            
            return mockAsset;
        };

        const response = await request(app).get(`/asset?id=${assetId}`);
        expect(response.statusCode).toBe(200);
        expect(response.body).toEqual(Buffer.from("ABCD"));
    });

    test("non existing asset yields a 404 error", async () => {

        const assetId = new ObjectId();
        const { app, mockCollection } = await initServer();

        mockCollection.findOne = (query: any) => {
            return undefined;
        };

        const response = await request(app).get(`/asset?id=${assetId}`);
        expect(response.statusCode).toBe(404);
    });



    test("get existing asset with no id yields an error", async () => {

        const { app } = await initServer();

        const response = await request(app).get(`/asset`);
        expect(response.statusCode).toBe(500);
    });

    test("check for existing asset by hash", async () => {

        const hash = "1234";
        const { app, mockCollection } = await initServer();

        const mockAsset: any = {};
        mockCollection.findOne = (query: any) => {
            expect(query.hash).toEqual(hash);
            
            return mockAsset;
        };

        const response = await request(app).get(`/check-asset?hash=${hash}`);
        expect(response.statusCode).toBe(200);
    });

    test("check for non-existing asset by hash", async () => {

        const hash = "1234";
        const { app, mockCollection } = await initServer();

        mockCollection.findOne = (query: any) => {
            return undefined;
        };

        const response = await request(app).get(`/check-asset?hash=${hash}`);
        expect(response.statusCode).toBe(404);
    });

    test("check for existing asset with no hash yields an error", async () => {

        const { app } = await initServer();

        const response = await request(app).get(`/check-asset`);
        expect(response.statusCode).toBe(500);
    });

    test("get assets", async () => {

        const skip = 2;
        const limit = 3;

        const { app, mockCollection } = await initServer();

        const mockAsset1: any = {
            contentType: "image/jpeg",
        };
        const mockAsset2: any = {
            contentType: "image/png",
        };

        mockCollection.find = () => {
            return {
                skip(value: number) {
                    expect(value).toBe(skip);

                    return {
                        limit(value: number) {
                            expect(value).toBe(limit);

                            return {
                                toArray() {
                                    return [ mockAsset1, mockAsset2 ];
                                },
                            };
                        }
                    };
                }
            };
        };

        const response = await request(app).get(`/assets?skip=${skip}&limit=${limit}`);
        
        expect(response.statusCode).toBe(200);
        expect(response.body).toEqual({
            assets: [ mockAsset1, mockAsset2 ],
        });
    });

});