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

        const fileName = "a-test-file.jpg";
        const contentType = "image/jpg";
        const width = 256;
        const height = 1024;
        const hash = "1234";

        const response = await request(app)
            .post("/asset")
            .set("file-name", fileName)
            .set("content-type", contentType)
            .set("width", width.toString())
            .set("height", height.toString())
            .set("hash", hash)
            .send(fs.readFileSync("./test/test-assets/1.jpeg"));

        const assetId = response.body.assetId;

        expect(response.statusCode).toBe(200);
        expect(assetId).toBeDefined();
        expect(assetId.length).toBeGreaterThan(0);

        expect(mockCollection.insertOne).toHaveBeenCalledTimes(1);
        expect(mockCollection.insertOne).toHaveBeenCalledWith({
            _id: new ObjectId(assetId),
            origFileName: fileName,
            contentType: contentType,
            src: `/asset?id=${assetId}`,
            thumb: `/asset?id=${assetId}`,
            width: width,
            height: height,
            hash: hash,
        });

        const uploadedFiles = await getUploads();
        expect(uploadedFiles).toEqual([
            assetId,
        ]);
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


