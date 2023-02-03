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
                    toArray() {
                        return [];
                    },
                };
            },
        };
        const mockDb: any = {
            collection() {
                return mockCollection;
            },
        };

        const app = createServer(mockDb);
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
        const response = await request(app).get("/assets");
        
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
            contentType: "image/jpg",
            width: 256,
            height: 1024,
            hash: "1234",
        };

        const response = await request(app)
            .post("/asset")
            .set("metadata", JSON.stringify(metadata))
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
            src: `/asset?id=${assetId}`,
            thumb: `/asset?id=${assetId}`,
            width: metadata.width,
            height: metadata.height,
            hash: metadata.hash,
        });

        const uploadedFiles = await getUploads();
        expect(uploadedFiles).toEqual([
            assetId,
        ]);
    });

    //
    // Uploads an asset with one of the required headers missing.
    //
    async function uploadAssetWithMissingHeader(headers: { [index: string]: string; }, missingHeader: string) {

        const { app } = await initServer();

        const req = request(app).post("/asset");

        for (const [header, value] of Object.entries(headers)) {
            if (header !== missingHeader) {
                req.set(header, value);
            }
        }
    
        const response = await req
            .send(fs.readFileSync("./test/test-assets/1.jpeg"));
    
        expect(response.statusCode).toBe(500);
    }
    
    test("upload asset with missing headers", async () => {

        const headers = {
            "file-name": "a-test-file.jpg",
            "content-type": "image/jpg",
            "width": "256",
            "height": "1024",
            "hash": "1234",
        };

        await uploadAssetWithMissingHeader(headers, "file-name");
        await uploadAssetWithMissingHeader(headers, "content-type");
        await uploadAssetWithMissingHeader(headers, "width");
        await uploadAssetWithMissingHeader(headers, "height");
        await uploadAssetWithMissingHeader(headers, "hash");
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

        const assetId = new ObjectId();
        const { app, mockCollection } = await initServer();

        const mockAsset1: any = {
            contentType: "image/jpeg",
        };
        const mockAsset2: any = {
            contentType: "image/png",
        };
        mockCollection.find = () => {
            return {
                toArray() {
                    return [ mockAsset1, mockAsset2 ];
                },
            };
        };

        const response = await request(app).get(`/assets`);
        
        expect(response.statusCode).toBe(200);
        expect(response.body).toEqual({
            assets: [ mockAsset1, mockAsset2 ],
        });
    });

});