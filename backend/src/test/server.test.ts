import { createServer } from "../server";
import * as fs from "fs-extra";
import request from "supertest";
import { ObjectId } from "mongodb";
import dayjs from "dayjs";
import { Readable } from "stream";

describe("photosphere backend", () => {

    const dateNow = dayjs("2023-02-08T01:27:01.419Z").toDate();

    //
    // Initialises the server for testing.
    //
    async function initServer() {

        const mockCollection: any = {
            find() {
                return {
                    sort() {
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
                    }
                };
            },

            findOne() {
            },

            createIndex() {
            },
        };

        const mockDb: any = {
            collection() {
                return mockCollection;
            },
        };

        const mockStorage: any = {
            init() {

            },
        };

        const app = await createServer(mockDb, () => dateNow, mockStorage);
        return { 
            app, 
            mockCollection, 
            mockDb,
            mockStorage,
        };
    }
    
    //
    // Creates a readable stream from a string.
    //
    function stringStream(content: string) {
        let contentSent = false;
        const stream = new Readable({
            read() {
                if (contentSent) {
                    this.push(null);
                }
                else {
                    this.push(content);
                    contentSent = true;
                }
            },
        });
        return stream;
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

        const { app, mockCollection, mockStorage } = await initServer();

        mockCollection.insertOne = jest.fn();
        mockStorage.write = jest.fn();

        const metadata = {
            fileName: "a-test-file.jpg",
            contentType: "image/jpeg",
            width: 256,
            height: 1024,
            hash: "1234",
            location: "Somewhere",
            fileDate: "2023-02-08T01:24:02.947Z",
            photoDate: "2023-02-08T01:28:26.735Z",
            properties: {
                "a": "property",
            },
            labels: [
                "Cool photo",
            ],
        };

        const response = await request(app)
            .post("/asset")
            .set("metadata", JSON.stringify(metadata))
            .send(fs.readFileSync("./test/test-assets/1.jpeg"));

        const assetId = response.body.assetId;

        expect(response.statusCode).toBe(200);
        expect(assetId).toBeDefined();
        expect(assetId.length).toBeGreaterThan(0);

        expect(mockStorage.write).toHaveBeenCalledTimes(1);
        expect(mockStorage.write.mock.calls[0][0]).toEqual("original");
        expect(mockStorage.write.mock.calls[0][1]).toEqual(assetId);

        expect(mockCollection.insertOne).toHaveBeenCalledTimes(1);
        expect(mockCollection.insertOne).toHaveBeenCalledWith({
            _id: new ObjectId(assetId),
            origFileName: metadata.fileName,
            contentType: metadata.contentType,
            width: metadata.width,
            height: metadata.height,
            hash: metadata.hash,
            location: metadata.location,
            properties: metadata.properties,
            fileDate: dayjs(metadata.fileDate).toDate(),
            photoDate: dayjs(metadata.photoDate).toDate(),
            sortDate: dayjs(metadata.photoDate).toDate(),
            uploadDate: dateNow,
            labels: metadata.labels,
        });
    });

    test("upload thumbnail", async () => {

        const { app, mockCollection, mockStorage } = await initServer();

        mockCollection.updateOne = jest.fn();
        mockStorage.write = jest.fn();

        const assetId = "63de0ba152be7661d4926bf1";

        const response = await request(app)
            .post("/thumb")
            .set("id", assetId)
            .set("content-type", "image/jpeg")
            .send(fs.readFileSync("./test/test-assets/1.jpeg"));

        expect(response.statusCode).toBe(200);

        expect(mockCollection.updateOne).toHaveBeenCalledTimes(1);
        expect(mockCollection.updateOne).toHaveBeenCalledWith(
            {
                _id: new ObjectId(assetId),
            },
            {
                $set: {
                    thumbContentType: "image/jpeg",
                },
            }
        );

        expect(mockStorage.write).toHaveBeenCalledTimes(1);
        expect(mockStorage.write.mock.calls[0][0]).toEqual("thumb");
        expect(mockStorage.write.mock.calls[0][1]).toEqual(assetId);
    });

    //
    // Uploads an asset with one of the required headers missing.
    //
    async function uploadAssetWithMissingMetadata(metadata: any, missingField: string) {

        const { app, mockCollection } = await initServer();

        mockCollection.insertOne = jest.fn();

        const req = request(app).post("/asset");

        const augumented = Object.assign({}, metadata);
        delete augumented[missingField];

        const response = await req
            .set("metadata", JSON.stringify(augumented))
            .send(fs.readFileSync("./test/test-assets/1.jpeg"));
    
        expect(response.statusCode).toBe(500);
    }
    
    test("upload asset with missing headers", async () => {

        const metadata = {
            fileName: "a-test-file.jpg",
            contentType: "image/jpeg",
            width: 256,
            height: 1024,
            hash: "1234",
            fileDate: "2023-02-08T01:24:02.947Z",
        };

        await uploadAssetWithMissingMetadata(metadata, "fileName");
        await uploadAssetWithMissingMetadata(metadata, "contentType");
        await uploadAssetWithMissingMetadata(metadata, "width");
        await uploadAssetWithMissingMetadata(metadata, "height");
        await uploadAssetWithMissingMetadata(metadata, "hash");
        await uploadAssetWithMissingMetadata(metadata, "fileDate");
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
        const { app, mockCollection, mockStorage } = await initServer();
        const content = "ABCD";
        const contentType = "image/jpeg";

        const mockAsset: any = {
            contentType: contentType,
        };
        mockCollection.findOne = (query: any) => {
            expect(query._id).toEqual(assetId);
            
            return mockAsset;
        };

        mockStorage.read = jest.fn((type: string, assetId: string) => {
            expect(type).toBe("original");
            expect(assetId).toBe(assetId);
            return stringStream(content);
        });

        const response = await request(app).get(`/asset?id=${assetId}`);
        expect(response.statusCode).toBe(200);
        expect(response.header["content-type"]).toBe(contentType);
        expect(response.body).toEqual(Buffer.from(content));
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

    test("get existing thumb", async () => {

        const assetId = new ObjectId();
        const content = "ABCD";
        const contentType = "image/jpeg";

        const { app, mockCollection, mockStorage } = await initServer();

        const mockAsset: any = {
            thumbContentType: contentType,
        };
        mockCollection.findOne = (query: any) => {
            expect(query._id).toEqual(assetId);
            return mockAsset;
        };
        mockStorage.read = jest.fn((type: string, assetId: string) => {
            expect(type).toBe("thumb");
            expect(assetId).toBe(assetId);
            return stringStream(content);
        });

        const response = await request(app).get(`/thumb?id=${assetId}`);
        expect(response.statusCode).toBe(200);
        expect(response.header["content-type"]).toBe(contentType);
        expect(response.body).toEqual(Buffer.from(content));
    });

    test("get thumb returns original asset when thumb doesn't exist", async () => {

        const assetId = new ObjectId();
        const content = "ABCD";
        const contentType = "image/jpeg";

        const { app, mockCollection, mockStorage } = await initServer();

        const mockAsset: any = {
            contentType: contentType,
        };
        mockCollection.findOne = (query: any) => {
            expect(query._id).toEqual(assetId);
            
            return mockAsset;
        };
        mockStorage.read = jest.fn((type: string, assetId: string) => {
            expect(type).toBe("original");
            expect(assetId).toBe(assetId);
            return stringStream(content);
        });

        const response = await request(app).get(`/thumb?id=${assetId}`);
        expect(response.statusCode).toBe(200);
        expect(response.header["content-type"]).toBe(contentType);
        expect(response.body).toEqual(Buffer.from(content));
    });

    test("non existing thumb yields a 404 error", async () => {

        const assetId = new ObjectId();
        const { app, mockCollection } = await initServer();

        mockCollection.findOne = (query: any) => {
            return undefined;
        };

        const response = await request(app).get(`/thumb?id=${assetId}`);
        expect(response.statusCode).toBe(404);
    });

    test("get existing thumb with no id yields an error", async () => {

        const { app } = await initServer();

        const response = await request(app).get(`/thumb`);
        expect(response.statusCode).toBe(500);
    });

    test("get existing display asset", async () => {

        const assetId = new ObjectId();
        const content = "ABCD";
        const contentType = "image/jpeg";

        const { app, mockCollection, mockStorage } = await initServer();

        const mockAsset: any = {
            displayContentType: contentType,
        };
        mockCollection.findOne = (query: any) => {
            expect(query._id).toEqual(assetId);
            return mockAsset;
        };
        mockStorage.read = jest.fn((type: string, assetId: string) => {
            expect(type).toBe("display");
            expect(assetId).toBe(assetId);
            return stringStream(content);
        });

        const response = await request(app).get(`/display?id=${assetId}`);
        expect(response.statusCode).toBe(200);
        expect(response.header["content-type"]).toBe(contentType);
        expect(response.body).toEqual(Buffer.from(content));
    });

    test("get display asset returns original asset when display asset doesn't exist", async () => {

        const assetId = new ObjectId();
        const content = "ABCD";
        const contentType = "image/jpeg";

        const { app, mockCollection, mockStorage } = await initServer();

        const mockAsset: any = {
            contentType: contentType,
        };
        mockCollection.findOne = (query: any) => {
            expect(query._id).toEqual(assetId);
            
            return mockAsset;
        };
        mockStorage.read = jest.fn((type: string, assetId: string) => {
            expect(type).toBe("original");
            expect(assetId).toBe(assetId);
            return stringStream(content);
        });

        const response = await request(app).get(`/display?id=${assetId}`);
        expect(response.statusCode).toBe(200);
        expect(response.header["content-type"]).toBe(contentType);
        expect(response.body).toEqual(Buffer.from(content));
    });

    test("non existing display asset yields a 404 error", async () => {

        const assetId = new ObjectId();
        const { app, mockCollection } = await initServer();

        mockCollection.findOne = (query: any) => {
            return undefined;
        };

        const response = await request(app).get(`/display?id=${assetId}`);
        expect(response.statusCode).toBe(404);
    });

    test("get existing display asset with no id yields an error", async () => {

        const { app } = await initServer();

        const response = await request(app).get(`/display`);
        expect(response.statusCode).toBe(500);
    });

    test("check for existing asset by hash", async () => {

        const hash = "1234";
        const { app, mockCollection } = await initServer();

        const mockAsset: any = {
            _id: "ABCD",
        };
        mockCollection.findOne = (query: any) => {
            expect(query.hash).toEqual(hash);
            
            return mockAsset;
        };

        const response = await request(app).get(`/check-asset?hash=${hash}`);
        expect(response.statusCode).toBe(200);
        expect(response.body.assetId).toEqual("ABCD");
    });

    test("check for non-existing asset by hash", async () => {

        const hash = "1234";
        const { app, mockCollection } = await initServer();

        mockCollection.findOne = (query: any) => {
            return undefined;
        };

        const response = await request(app).get(`/check-asset?hash=${hash}`);
        expect(response.statusCode).toBe(200);
        expect(response.body.assetId).toBeUndefined();
    });

    test("check for existing asset with no hash yields an error", async () => {

        const { app } = await initServer();

        const response = await request(app).get(`/check-asset`);
        expect(response.statusCode).toBe(500);
    });

    test("can get assets", async () => {

        const skip = 2;
        const limit = 3;

        const { app, mockCollection } = await initServer();

        const mockAsset1: any = {
            contentType: "image/jpeg",
        };
        const mockAsset2: any = { 
            contentType: "image/png",
        };

        mockCollection.find = (query: any) => {
            expect(query).toEqual({}); // Expect no search query.

            return {
                sort() {
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
                }
            };
        };

        const response = await request(app).get(`/assets?skip=${skip}&limit=${limit}`);
        
        expect(response.statusCode).toBe(200);
        expect(response.body).toEqual({
            assets: [ mockAsset1, mockAsset2 ],
        });
    });

    test("can add label to asset", async () => {

        const { app, mockCollection } = await initServer();

        mockCollection.updateOne = jest.fn();

        const id = new ObjectId();
        const label = "A good label";

        const response = await request(app)
            .post(`/asset/add-label`)
            .send({
                id: id,
                label: label,
            });

        expect(response.statusCode).toBe(200);
        
        expect(mockCollection.updateOne).toBeCalledTimes(1);
        expect(mockCollection.updateOne).toHaveBeenCalledWith(
            { _id: id },
            { 
                $push: {
                    labels: label,
                },
            }
        );
    });

    test("can remove label from asset", async () => {

        const { app, mockCollection } = await initServer();

        mockCollection.updateOne = jest.fn();

        const id = new ObjectId();
        const label = "A good label";

        const response = await request(app)
            .post(`/asset/remove-label`)
            .send({
                id: id,
                label: label,
            });

        expect(response.statusCode).toBe(200);
        
        expect(mockCollection.updateOne).toBeCalledTimes(1);
        expect(mockCollection.updateOne).toHaveBeenCalledWith(
            { _id: id },
            { 
                $pull: {
                    labels: label,
                },
            }
        );
    });

    test("can set description for asset", async () => {

        const { app, mockCollection } = await initServer();

        mockCollection.updateOne = jest.fn();

        const id = new ObjectId();
        const description = "A good description";

        const response = await request(app)
            .post(`/asset/description`)
            .send({
                id: id,
                description: description,
            });

        expect(response.statusCode).toBe(200);
        
        expect(mockCollection.updateOne).toBeCalledTimes(1);
        expect(mockCollection.updateOne).toHaveBeenCalledWith(
            { _id: id },
            { 
                $set: {
                    description: description,
                },
            }
        );
    });

    test("can search assets", async () => {

        const skip = 2;
        const limit = 3;

        const { app, mockCollection } = await initServer();

        const mockAsset: any = {
            contentType: "image/jpeg",
        };

        mockCollection.find = (query: any) => {
            expect(query).toEqual({ 
                $text: { 
                    $search: 'something' 
                },
            });
            
            return {
                sort() {
                    return {
                        skip(value: number) {
                            expect(value).toBe(skip);
        
                            return {
                                limit(value: number) {
                                    expect(value).toBe(limit);
        
                                    return {
                                        toArray() {
                                            return [ mockAsset ];
                                        },
                                    };
                                }
                            };
                        }
                    };
                }
            };
        };

        const searchText = "something";
        const response = await request(app).get(`/assets?skip=${skip}&limit=${limit}&search=${searchText}`);
        
        expect(response.statusCode).toBe(200);
        expect(response.body).toEqual({
            assets: [ mockAsset ],
        });
    });

});

