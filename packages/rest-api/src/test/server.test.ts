import { createServer } from "../lib/server";
import * as fs from "fs-extra";
import * as path from "path";
import dayjs from "dayjs";
import { Readable } from "stream";
import { AddressInfo } from "net";
import axios from "axios";
import http, { IncomingMessage } from "http";

describe("photosphere backend", () => {

    const dateNow = dayjs("2023-02-08T01:27:01.419Z").toDate();
    const setId = "automated-tests-collection";

    let servers: { server: http.Server, close: () => Promise<void> }[] = [];

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
            getOne: jest.fn().mockResolvedValue(null),
            getSorted: jest.fn().mockResolvedValue({ records: [], nextPageId: null }),
            ensureSortIndex: jest.fn(),
            findByIndex: jest.fn().mockResolvedValue([]),
            find: () => ({
                sort: () => ({
                    skip: () => ({
                        limit: () => ({
                            toArray: async () => [],
                        }),
                    }),
                }),
                toArray: async () => [],
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

        const mockMediaFileDatabaseProvider = {
            listAssetDatabases: jest.fn().mockResolvedValue([{id: setId, name: setId}]),
            openDatabase: jest.fn().mockResolvedValue({
                getAllAssets: jest.fn().mockResolvedValue([]),
                getMetadataDatabase: jest.fn().mockReturnValue({
                    collection: (name: string) => {
                        const collection = collections[name];
                        if (!collection) {
                            throw new Error(`No mock collection for ${name}`);
                        }
                        return collection;
                    }
                }),
                close: jest.fn()
            }),
            readStream: jest.fn().mockReturnValue(stringStream("ABCD")),
            write: jest.fn().mockResolvedValue(undefined),
            close: jest.fn()
        };

        const { app, close } = await createServer(() => dateNow, mockMediaFileDatabaseProvider, mockStorage, {
            appMode: "readwrite",
            authType: "no-auth"
        });

        const server = app.listen();
        servers.push({ server, close });

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
            mockMediaFileDatabaseProvider,
         };
    }

    beforeAll(() => {
        axios.defaults.validateStatus = () => {
            return true;
        };
    });
  
    afterEach(() => {
        for (const server of servers) {
            server.server.close();
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
        const { baseUrl } = await initServer();

        const response = await axios.get(`${baseUrl}/dbs`);
        expect(response.status).toBe(200);
        expect(response.data).toEqual({ dbs: [{id: setId, name: setId}] });
    });
    
    test("no assets", async () => {
        const { baseUrl } = await initServer();

        const response = await axios.get(`${baseUrl}/get-all?db=${setId}&col=metadata&skip=0&limit=100`);
        expect(response.status).toBe(200);
        expect(response.data).toEqual({
            records: [],
            next: null,
        });
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
                databaseId: setId,
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
            assetId,
            withDates,
            { upsert: true }
        );
        // Journal operations are not implemented in this version of the API
    });

    test("upload asset data", async () => {

        const { baseUrl, mockMediaFileDatabaseProvider } = await initServer();

        const assetId = "63de0ba152be7661d4926bf1";
        const contentType = "image/jpeg";
        const assetType = "original";

        const response = await axios.post(
            `${baseUrl}/asset`, 
            fs.readFileSync(path.resolve(__dirname, "../../../../test/test.jpg")),
            {
                headers: { 
                    "db": setId,
                    "id": assetId,
                    "Content-Type": contentType,
                    "asset-type": assetType,
                },
            }
        );

        expect(response.status).toBe(200);

        expect(mockMediaFileDatabaseProvider.write).toHaveBeenCalledTimes(1);
        expect(mockMediaFileDatabaseProvider.write).toHaveBeenCalledWith(
            setId, assetType, assetId, contentType, expect.any(Buffer)
        );
    });

    test("get existing asset", async () => {

        const assetId = "1234";
        const { baseUrl, mockMediaFileDatabaseProvider } = await initServer();
        const content = "ABCD";
        const contentType = "image/jpeg";

        const stream = stringStream(content);
        // Mock headers property on stream
        (stream as any).headers = { 'content-type': contentType };
        
        // Override pipe to set headers on destination
        const originalPipe = stream.pipe.bind(stream);
        (stream as any).pipe = function(destination: any, options?: any) {
            if (destination && destination.setHeader) {
                destination.setHeader('content-type', contentType);
            }
            return originalPipe(destination, options);
        };
        
        mockMediaFileDatabaseProvider.readStream.mockReturnValue(stream);

        const response = await axios.get(`${baseUrl}/asset?id=${assetId}&db=${setId}&type=original`);
        expect(response.status).toBe(200);
        expect(response.headers["content-type"]).toBe(contentType);
        expect(response.data).toEqual(content);
    });

    test("non existing asset yields a 404 error", async () => {

        const assetId = "1234";
        const { baseUrl, mockMediaFileDatabaseProvider } = await initServer();

        mockMediaFileDatabaseProvider.readStream.mockImplementation(() => {
            throw new Error('File not found');
        });

        const response = await axios.get(`${baseUrl}/asset?id=${assetId}&db=${setId}&type=original`);
        expect(response.status).toBe(500);
    });

    test("get existing asset with no id yields an error", async () => {

        const { baseUrl } = await initServer();

        const response = await axios.get(`${baseUrl}/asset?db=${setId}&type=original`);
        expect(response.status).toBe(400);
    });

    test("check for existing asset by hash", async () => {

        const assetId = "1234";
        const { baseUrl, mockMetadataCollection } = await initServer();

        mockMetadataCollection.findByIndex = jest.fn().mockResolvedValue([{ _id: assetId }]);
      
        const hash = "ABCD";
        const response = await axios.get(`${baseUrl}/check-hash?hash=${hash}&db=${setId}`);
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
        const response = await axios.get(`${baseUrl}/check-hash?hash=${hash}&db=${setId}`);
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

        mockMetadataCollection.getSorted.mockResolvedValue({
            records: [ mockAsset1, mockAsset2 ],
            nextPageId: null
        });

        const response = await axios.get(`${baseUrl}/get-all?db=${setId}&col=metadata&skip=2&limit=3`);
        
        expect(response.status).toBe(200);
        expect(response.data).toEqual({
            records: [ mockAsset1, mockAsset2 ],
            next: null,
        });
    });
});

