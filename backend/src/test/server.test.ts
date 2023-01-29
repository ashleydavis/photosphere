import { createServer } from "../server";
import request from "supertest";
import * as fs from "fs";
import { ObjectId } from "mongodb";

describe("photosphere backend", () => {

    //
    // Initialises the server for testing.
    //
    function initServer() {
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

    test("no assets", async () => {

        const { app } = initServer();
        const response = await request(app).get("/assets");
        
        expect(response.statusCode).toBe(200);
        expect(response.body).toEqual({ 
            assets: [],
        });
    });

    test("upload asset", async () => {

        const { app, mockCollection } = initServer();

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
    });
});

