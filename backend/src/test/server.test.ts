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
        const mockUsersCollection: any = {
            findOne: async () => mockUser,
        };
        const mockJournalCollection: any = {
            insertOne: jest.fn(),
        };
        const mockMetadataCollection: any = {
            updateOne: jest.fn(),
            find: () => ({
                sort: () => ({
                    skip: () => ({
                        limit: () => ({
                            toArray: async () => [],
                        }),
                    }),
                })
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

        const app = await createServer(() => dateNow, mockDatabase, mockStorage, "");

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

        const withDates = {
            ...metadata,
            fileDate: dayjs(metadata.fileDate).toDate(),
            photoDate: dayjs(metadata.photoDate).toDate(),
        };

        expect(mockMetadataCollection.updateOne).toHaveBeenCalledTimes(1);
        expect(mockMetadataCollection.updateOne).toHaveBeenCalledWith(
            { _id: assetId },
            { $set: withDates },
            { upsert: true }
        );
        expect(mockJournalCollection.insertOne).toHaveBeenCalledTimes(1);
        expect(mockJournalCollection.insertOne).toHaveBeenCalledWith(
            expect.objectContaining({
                _id: expect.any(String),
                serverTime: expect.any(Date),
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
                    "set": setId,
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

        const response = await axios.get(`${baseUrl}/asset?id=${assetId}&set=${setId}&type=original`);
        expect(response.status).toBe(200);
        expect(response.headers["content-type"]).toBe(contentType);
        expect(response.data).toEqual(content);
    });

    test("non existing asset yields a 404 error", async () => {

        const assetId = "1234";
        const { baseUrl, mockStorage } = await initServer();

        mockStorage.info = async () => undefined;

        const response = await axios.get(`${baseUrl}/asset?id=${assetId}&set=${setId}&type=original`);
        expect(response.status).toBe(404);
    });

    test("get existing asset with no id yields an error", async () => {

        const { baseUrl } = await initServer();

        const response = await axios.get(`${baseUrl}/asset?set=${setId}&type=original`);
        expect(response.status).toBe(400);
    });

    test("check for existing asset by hash", async () => {

        const assetId = "1234";
        const { baseUrl, mockMetadataCollection } = await initServer();

        mockMetadataCollection.find = () => {
            return {
                toArray: async () => [{ _id: assetId }],
            };
        };
      
        const hash = "ABCD";
        const response = await axios.get(`${baseUrl}/check-hash?hash=${hash}&set=${setId}`);
        expect(response.status).toBe(200);
        expect(response.data).toEqual({ assetIds: [ assetId ] });
    });

    test("check for non-existing asset by hash", async () => {

        const { baseUrl, mockMetadataCollection } = await initServer();
        
        mockMetadataCollection.find = () => {
            return {
                toArray: async () => [],
            };
        };

        const hash = "1234";
        const response = await axios.get(`${baseUrl}/check-hash?hash=${hash}&set=${setId}`);
        expect(response.status).toBe(200);
        expect(response.data).toEqual({ assetIds: [] });
    });

    test("can get assets", async () => {

        const { baseUrl, mockMetadataCollection } = await initServer();

        const mockAsset1: any = {
            contentType: "image/jpeg",
        };

        const mockAsset2: any = { 
            contentType: "image/png",
        };

        mockMetadataCollection.find = () => {
            return {
                sort: () => ({
                    skip: () => ({
                        limit: () => ({
                            toArray: async () => [ mockAsset1, mockAsset2 ],
                        }),
                    }),
                })
            };
        };

        const response = await axios.get(`${baseUrl}/get-all?set=${setId}&skip=2&limit=3&col=metadata`);
        
        expect(response.status).toBe(200);
        expect(response.data).toEqual([ mockAsset1, mockAsset2 ]);
    });
});

