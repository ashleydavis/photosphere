import { createServer } from "../server";
import * as fs from "fs-extra";
import dayjs from "dayjs";
import { Readable } from "stream";
import { AddressInfo } from "net";
import axios from "axios";
import http, { IncomingMessage } from "http";

describe("photosphere backend", () => {

    const dateNow = dayjs("2023-02-08T01:27:01.419Z").toDate();
    const setId = "automated-tests-collection";

    let servers: http.Server[] = [];

    //
    // Initialises the server for testing.
    //
    async function initServer() {

        const mockUser = {
            _id: "test-user",
            sets: {
                upload: "upload",
                default: "default",
                access: [ "access" ],
            },
        };
    
        const mockStorage: any = {};
        const mockUsersCollection = {
            findOne: async () => mockUser,
        };
        const mockJournalCollection = {
            insertOne: jest.fn(),
        };
        const mockMetadataCollection = {
            updateOne: jest.fn(),
            find: () => ({
                skip: () => ({
                    limit: () => ({
                        toArray: async () => [],
                    }),
                }),
            }),
        };
        const collections: any = {
            users: mockUsersCollection,
            metadata: mockMetadataCollection,
            journal: mockJournalCollection,
        };
        const mockDatabase: any = {
            collection: (name: string) => {
                const collection = collections[name];
                if (!collection) {
                    throw new Error(`No mock collection for ${name}`);
                }
                return collection;
            },
        };

        const app = await createServer(() => dateNow, mockDatabase, mockStorage);

        const server = app.listen();
        servers.push(server);

        const address = server.address() as AddressInfo;
        const baseUrl = `http://localhost:${address.port}`;

        return { 
            app, 
            server, 
            baseUrl, 
            mockDatabase, 
            mockStorage, 
            mockUser,
            mockJournalCollection,
            mockMetadataCollection,
         };
    }

    beforeAll(() => {
        axios.defaults.validateStatus = () => {
            return true;
        };
    });
  
    afterEach(() => {
        for (const server of servers) {
            server.close();
        }
        servers = [];
    });
    
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

    test("user metadata", async () => {
        const { baseUrl, mockUser } = await initServer();

        const response = await axios.get(`${baseUrl}/user`);
        expect(response.status).toBe(200);
        expect(response.data).toEqual(mockUser);
    });
    
    test("no assets", async () => {
        const { baseUrl } = await initServer();

        const response = await axios.get(`${baseUrl}/get-all?set=${setId}&col=metadata&skip=0&limit=100`);
        expect(response.status).toBe(200);
        expect(response.data).toEqual([]);
    });

    test("upload asset metadata", async () => {

        const { baseUrl, mockMetadataCollection, mockJournalCollection } = await initServer();

        //fio:
        // const mockCollection: any = {
        //     getOne: async () => undefined,
        //     setOne: jest.fn(),
        // };
        // const mockDatabase: any = {
        //     collection: () => mockCollection,
        // };
        //todo:
        // mockDatabases.database = async () => mockDatabase;

        const assetId = "1234";
        const hash = "ACBD";
        const metadata = {
            _id: assetId,
            col: setId,
            fileName: "a-test-file.jpg",
            contentType: "image/jpeg",
            width: 256,
            height: 1024,
            hash,
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

        const response = await axios.post(`${baseUrl}/operations`, {
            clientId: "test-client",
            ops: [{
                collectionName: "metadata",
                setId,
                recordId: assetId,
                op: {
                    type: "set",
                    fields: metadata,
                },
            }],
        });

        expect(response.status).toBe(200);

        expect(mockMetadataCollection.updateOne).toHaveBeenCalledTimes(1);
        expect(mockMetadataCollection.updateOne).toHaveBeenCalledWith(
            { _id: assetId },
            { $set: metadata },
            { upsert: true }
        );
        expect(mockJournalCollection.insertOne).toHaveBeenCalledTimes(1);
        expect(mockJournalCollection.insertOne).toHaveBeenCalledWith(
            expect.objectContaining({
                _id: expect.any(String),
                serverTime: expect.any(String),
                sequence: expect.any(Number),
                clientId: "test-client",
                collectionName: "metadata",
                recordId: assetId,
                op: {
                    type: "set",
                    fields: metadata,
                },
            })
        );
    });

    test("upload asset data", async () => {

        const { baseUrl, mockStorage } = await initServer();

        mockStorage.writeStream = jest.fn();

        const assetId = "63de0ba152be7661d4926bf1";
        const contentType = "image/jpeg";
        const assetType = "original";

        const response = await axios.post(
            `${baseUrl}/asset`, 
            fs.readFileSync("./test/test-assets/1.jpeg"),
            {
                headers: { 
                    "col": setId,
                    "id": assetId,
                    "Content-Type": contentType,
                    "asset-type": assetType,
                },
            }
        );

        expect(response.status).toBe(200);

        expect(mockStorage.writeStream).toHaveBeenCalledTimes(1);
        expect(mockStorage.writeStream).toHaveBeenCalledWith(
            `collections/${setId}/${assetType}`, assetId, contentType, expect.any(IncomingMessage)
        );
    });

    test("get existing asset", async () => {

        const assetId = "1234";
        const { baseUrl, mockStorage } = await initServer();
        const content = "ABCD";
        const contentType = "image/jpeg";

        mockStorage.info = async () => ({ contentType });
        mockStorage.readStream = () => stringStream(content);

        const response = await axios.get(`${baseUrl}/asset?id=${assetId}&col=${setId}&type=original`);
        expect(response.status).toBe(200);
        expect(response.headers["content-type"]).toBe(contentType);
        expect(response.data).toEqual(content);
    });

    test("non existing asset yields a 404 error", async () => {

        const assetId = "1234";
        const { baseUrl, mockStorage } = await initServer();

        mockStorage.info = async () => undefined;

        const response = await axios.get(`${baseUrl}/asset?id=${assetId}&col=${setId}&type=original`);
        expect(response.status).toBe(404);
    });

    test("get existing asset with no id yields an error", async () => {

        const { baseUrl } = await initServer();

        const response = await axios.get(`${baseUrl}/asset?col=${setId}&type=original`);
        expect(response.status).toBe(400);
    });

    test("check for existing asset by hash", async () => {

        const assetId = "1234";
        const { baseUrl } = await initServer();

        const mockCollection: any = {
            getOne: async () => [ assetId ],
        };
        const mockDatabase: any = {
            collection: () => mockCollection,
        };
       
        const hash = "ABCD";
        const response = await axios.get(`${baseUrl}/check-asset?hash=${hash}&col=${setId}`);
        expect(response.status).toBe(200);
        expect(response.data.assetId).toEqual(assetId);
    });

    test("check for non-existing asset by hash", async () => {

        const { baseUrl } = await initServer();
        
        const mockCollection: any = {
            getOne: async () => undefined,
        };
        const mockDatabase: any = {
            collection: () => mockCollection,
        };

        const hash = "1234";
        const response = await axios.get(`${baseUrl}/check-asset?hash=${hash}&col=${setId}`);
        expect(response.status).toBe(200);
        expect(response.data.assetId).toBeUndefined();
    });

    test("check for existing asset with no hash yields an error", async () => {

        const { baseUrl } = await initServer();

        const response = await axios.get(`${baseUrl}/check-asset?col=${setId}`);
        expect(response.status).toBe(400);
    });

    test("can get assets", async () => {

        const { baseUrl } = await initServer();

        const mockAsset1: any = {
            contentType: "image/jpeg",
        };

        const mockAsset2: any = { 
            contentType: "image/png",
        };

        const mockCollection: any = {
            getAll: async () => ({ records: [ mockAsset1, mockAsset2 ] }),
        };
        const mockDatabase: any = {
            collection: () => mockCollection,
        };

        const response = await axios.get(`${baseUrl}/assets?col=${setId}`);
        
        expect(response.status).toBe(200);
        expect(response.data).toEqual({
            assets: [ mockAsset1, mockAsset2 ],
        });
    });
});

