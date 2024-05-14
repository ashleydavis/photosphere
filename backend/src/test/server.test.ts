import { createServer } from "../server";
import * as fs from "fs-extra";
import dayjs from "dayjs";
import { Readable } from "stream";
import { AddressInfo } from "net";
import axios from "axios";
import http, { IncomingMessage } from "http";

describe("photosphere backend", () => {

    const dateNow = dayjs("2023-02-08T01:27:01.419Z").toDate();
    const collectionId = "automated-tests-collection";

    let servers: http.Server[] = [];

    //
    // Initialises the server for testing.
    //
    async function initServer() {

        const mockUserCollection: any = {
            getOne: () => ({
            }),
        };
        const mockDatabases: any = {};
        const mockStorage: any = {};
        const app = await createServer(() => dateNow, mockDatabases, mockUserCollection, mockStorage);

        const server = app.listen();
        servers.push(server);

        const address = server.address() as AddressInfo;
        const baseUrl = `http://localhost:${address.port}`;

        return { app, server, baseUrl, mockStorage, mockDatabases, mockUserCollection };        
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
        const { baseUrl, mockUserCollection: mockUserDatabase } = await initServer();

        const mockUser = {
            _id: "test-user",
            collections: {
                upload: "upload",
                default: "default",
                access: [ "access" ],
            },
        };
        mockUserDatabase.getOne = async () => mockUser;

        const response = await axios.get(`${baseUrl}/user`);
        expect(response.status).toBe(200);
        expect(response.data).toEqual(mockUser);
    });
    
    test("no assets", async () => {
        const { baseUrl, mockDatabases } = await initServer();

        const mockCollection: any = {
            getAll: async () => ({ records: [] }),
        };
        const mockDatabase: any = {
            collection: () => mockCollection,
        };
        mockDatabases.database = async () => mockDatabase;

        const response = await axios.get(`${baseUrl}/assets?col=${collectionId}`);

        expect(response.status).toBe(200);
        expect(response.data).toEqual({ assets: [] });
    });

    test("upload asset metadata", async () => {

        const { baseUrl, mockDatabases } = await initServer();

        const mockCollection: any = {
            getOne: async () => undefined,
            setOne: jest.fn(),
        };
        const mockDatabase: any = {
            collection: () => mockCollection,
        };
        mockDatabases.database = async () => mockDatabase;

        const assetId = "1234";
        const hash = "ACBD";
        const metadata = {
            _id: assetId,
            col: collectionId,
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
                databaseName: collectionId,
                collectionName: "metadata",
                recordId: assetId,
                op: {
                    type: "set",
                    fields: metadata,
                },
            }],
        });

        expect(response.status).toBe(200);

        expect(mockCollection.setOne).toHaveBeenCalledTimes(2);
        expect(mockCollection.setOne).toHaveBeenCalledWith(expect.any(String), {
            clientId: "test-client", 
            collectionName: "metadata", 
            op: {
                fields: {
                    ...metadata,

                }, 
                type: "set"
            }, 
            recordId: "1234", 
            serverTime: expect.any(String),
        });
        expect(mockCollection.setOne).toHaveBeenCalledWith(assetId, {
            ...metadata,
        });
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
                    "col": collectionId,
                    "id": assetId,
                    "Content-Type": contentType,
                    "asset-type": assetType,
                },
            }
        );

        expect(response.status).toBe(200);

        expect(mockStorage.writeStream).toHaveBeenCalledTimes(1);
        expect(mockStorage.writeStream).toHaveBeenCalledWith(
            `collections/${collectionId}/${assetType}`, assetId, contentType, expect.any(IncomingMessage)
        );
    });

    test("get existing asset", async () => {

        const assetId = "1234";
        const { baseUrl, mockStorage } = await initServer();
        const content = "ABCD";
        const contentType = "image/jpeg";

        mockStorage.info = async () => ({ contentType });
        mockStorage.readStream = () => stringStream(content);

        const response = await axios.get(`${baseUrl}/asset?id=${assetId}&col=${collectionId}&type=original`);
        expect(response.status).toBe(200);
        expect(response.headers["content-type"]).toBe(contentType);
        expect(response.data).toEqual(content);
    });

    test("non existing asset yields a 404 error", async () => {

        const assetId = "1234";
        const { baseUrl, mockStorage } = await initServer();

        mockStorage.info = async () => undefined;

        const response = await axios.get(`${baseUrl}/asset?id=${assetId}&col=${collectionId}&type=original`);
        expect(response.status).toBe(404);
    });

    test("get existing asset with no id yields an error", async () => {

        const { baseUrl } = await initServer();

        const response = await axios.get(`${baseUrl}/asset?col=${collectionId}&type=original`);
        expect(response.status).toBe(400);
    });

    test("check for existing asset by hash", async () => {

        const assetId = "1234";
        const { baseUrl, mockDatabases } = await initServer();

        const mockCollection: any = {
            getOne: async () => [ assetId ],
        };
        const mockDatabase: any = {
            collection: () => mockCollection,
        };
        mockDatabases.database = async () => mockDatabase;

       
        const hash = "ABCD";
        const response = await axios.get(`${baseUrl}/check-asset?hash=${hash}&col=${collectionId}`);
        expect(response.status).toBe(200);
        expect(response.data.assetId).toEqual(assetId);
    });

    test("check for non-existing asset by hash", async () => {

        const { baseUrl, mockDatabases } = await initServer();
        
        const mockCollection: any = {
            getOne: async () => undefined,
        };
        const mockDatabase: any = {
            collection: () => mockCollection,
        };
        mockDatabases.database = async () => mockDatabase;

        const hash = "1234";
        const response = await axios.get(`${baseUrl}/check-asset?hash=${hash}&col=${collectionId}`);
        expect(response.status).toBe(200);
        expect(response.data.assetId).toBeUndefined();
    });

    test("check for existing asset with no hash yields an error", async () => {

        const { baseUrl } = await initServer();

        const response = await axios.get(`${baseUrl}/check-asset?col=${collectionId}`);
        expect(response.status).toBe(400);
    });

    test("can get assets", async () => {

        const { baseUrl, mockDatabases } = await initServer();

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
        mockDatabases.database = async () => mockDatabase;

        const response = await axios.get(`${baseUrl}/assets?col=${collectionId}`);
        
        expect(response.status).toBe(200);
        expect(response.data).toEqual({
            assets: [ mockAsset1, mockAsset2 ],
        });
    });
});

