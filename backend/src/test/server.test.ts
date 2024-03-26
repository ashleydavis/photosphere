import { createServer } from "../server";
import * as fs from "fs-extra";
import dayjs from "dayjs";
import { Readable } from "stream";
import { AddressInfo } from "net";
import axios from "axios";
import http, { IncomingMessage } from "http";
import { IAsset } from "../lib/asset";
import { mock } from "node:test";

describe("photosphere backend", () => {

    const dateNow = dayjs("2023-02-08T01:27:01.419Z").toDate();

    let servers: http.Server[] = [];

    //
    // Initialises the server for testing.
    //
    async function initServer() {
        const mockAssetDatabase: any = {};
        const app = await createServer(() => dateNow, mockAssetDatabase);

        const server = app.listen();
        servers.push(server);

        const address = server.address() as AddressInfo;
        const baseUrl = `http://localhost:${address.port}`;

        return { app, server, baseUrl, mockAssetDatabase };        
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
    
    test("no assets", async () => {
        const { baseUrl, mockAssetDatabase } = await initServer();

        mockAssetDatabase.getAssets = async () => ({ assets: [] });

        const response = await axios.get(`${baseUrl}/assets`);

        expect(response.status).toBe(200);
        expect(response.data).toEqual({ assets: [] });
    });

    test("upload asset metadata", async () => {

        const { baseUrl, mockAssetDatabase } = await initServer();

        mockAssetDatabase.addMetadata = jest.fn();

        const hash = "!234";
        const metadata = {
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

        const response = await axios.post(`${baseUrl}/metadata`, metadata);

        const assetId = response.data.assetId;

        expect(response.status).toBe(200);
        expect(assetId).toBeDefined();
        expect(assetId.length).toBeGreaterThan(0);

        expect(mockAssetDatabase.addMetadata).toHaveBeenCalledTimes(1);
        expect(mockAssetDatabase.addMetadata).toHaveBeenCalledWith(assetId, hash, {
            _id: assetId,
            origFileName: metadata.fileName,
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

    test("upload asset original", async () => {

        const { baseUrl, mockAssetDatabase } = await initServer();

        mockAssetDatabase.uploadOriginal = jest.fn();

        const assetId = "63de0ba152be7661d4926bf1";
        const contentType = "image/jpeg";

        const response = await axios.post(
            `${baseUrl}/asset`, 
            fs.readFileSync("./test/test-assets/1.jpeg"),
            {
                headers: { 
                    'id': assetId,
                    'Content-Type': contentType,
                },
            }
        );

        expect(response.status).toBe(200);

        expect(mockAssetDatabase.uploadOriginal).toHaveBeenCalledTimes(1);
        expect(mockAssetDatabase.uploadOriginal).toHaveBeenCalledWith(assetId, contentType, expect.any(IncomingMessage));
    });

    test("upload thumbnail", async () => {

        const { baseUrl, mockAssetDatabase } = await initServer();

        mockAssetDatabase.uploadThumbnail = jest.fn();

        const assetId = "63de0ba152be7661d4926bf1";
        const contentType = "image/jpeg";

        const response = await axios.post(
            `${baseUrl}/thumb`, 
            fs.readFileSync("./test/test-assets/1.jpeg"), {
                headers: { 
                    'id': assetId, 
                    'Content-Type': contentType,
                },
            }
        );

        expect(response.status).toBe(200);

        expect(mockAssetDatabase.uploadThumbnail).toHaveBeenCalledTimes(1);
        expect(mockAssetDatabase.uploadThumbnail).toHaveBeenCalledWith(assetId, contentType, expect.any(IncomingMessage));
    });

    //
    // Uploads an asset with one of the required headers missing.
    //
    async function uploadAssetWithMissingMetadata(metadata: any, missingField: string) {

        const { baseUrl, mockAssetDatabase } = await initServer();

        mockAssetDatabase.setOne = jest.fn();
        mockAssetDatabase.write = jest.fn();

        const augumented = Object.assign({}, metadata);
        delete augumented[missingField];

        const response = await axios.post(`${baseUrl}/metadata`, augumented);
    
        expect(response.status).toBe(500);
    }
    
    test("upload asset with missing headers", async () => {

        const metadata = {
            fileName: "a-test-file.jpg",
            width: 256,
            height: 1024,
            hash: "1234",
            fileDate: "2023-02-08T01:24:02.947Z",
        };

        await uploadAssetWithMissingMetadata(metadata, "fileName");
        await uploadAssetWithMissingMetadata(metadata, "width");
        await uploadAssetWithMissingMetadata(metadata, "height");
        await uploadAssetWithMissingMetadata(metadata, "hash");
        await uploadAssetWithMissingMetadata(metadata, "fileDate");
    });

    //
    // Uploads a asset mneta with the specified headers.
    //
    async function uploadMetadata(metadata: any) {

        const { baseUrl, mockAssetDatabase } = await initServer();

        mockAssetDatabase.write = jest.fn();
        mockAssetDatabase.setOne = jest.fn();

        const defaultMetadata = {
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

        const uploadMetadata = Object.assign({}, defaultMetadata, metadata);

        return await axios.post(`${baseUrl}/metadata`, uploadMetadata);
    }
    
    //
    //TODO: Be great to get validation back online for these tests.
    //
    // test("upload metadata with bad width", async () => {

    //     const metadata = {
    //         "width": "---",
    //     };

    //     const response = await uploadMetadata(metadata);
    //     expect(response.status).toBe(500);
    // });

    // test("upload metadata with bad height", async () => {

    //     const headers = {
    //         "height": "---",
    //     };

    //     const response = await uploadMetadata(headers);
    //     expect(response.status).toBe(500);
    // });

    test("get existing asset", async () => {

        const assetId = "1234";
        const { baseUrl, mockAssetDatabase } = await initServer();
        const content = "ABCD";
        const contentType = "image/jpeg";

        mockAssetDatabase.streamOriginal = () => ({
            contentType,
            stream: stringStream(content),
        });

        const response = await axios.get(`${baseUrl}/asset?id=${assetId}`);
        expect(response.status).toBe(200);
        expect(response.headers["content-type"]).toBe(contentType);
        expect(response.data).toEqual(content);
    });

    test("non existing asset yields a 404 error", async () => {

        const assetId = "1234";
        const { baseUrl, mockAssetDatabase } = await initServer();

        mockAssetDatabase.streamOriginal = async () => undefined;

        const response = await axios.get(`${baseUrl}/asset?id=${assetId}`);
        expect(response.status).toBe(404);
    });

    test("get existing asset with no id yields an error", async () => {

        const { baseUrl } = await initServer();

        const response = await axios.get(`${baseUrl}/asset`);
        expect(response.status).toBe(400);
    });

    test("get existing thumb", async () => {

        const assetId = "1234";
        const content = "ABCD";
        const contentType = "image/jpeg";

        const { baseUrl, mockAssetDatabase } = await initServer();

        mockAssetDatabase.streamThumbnail = () => ({
            contentType,
            stream: stringStream(content),
        });

        const response = await axios.get(`${baseUrl}/thumb?id=${assetId}`);
        expect(response.status).toBe(200);
        expect(response.headers["content-type"]).toBe(contentType);
        expect(response.data).toEqual(content);
    });

    test("non existing thumb yields a 404 error", async () => {

        const assetId = "1234";
        const { baseUrl, mockAssetDatabase } = await initServer();

        mockAssetDatabase.streamThumbnail = () => undefined;

        const response = await axios.get(`${baseUrl}/thumb?id=${assetId}`);
        expect(response.status).toBe(404);
    });

    test("get existing thumb with no id yields an error", async () => {

        const { baseUrl } = await initServer();

        const response = await axios.get(`${baseUrl}/thumb`);
        expect(response.status).toBe(400);
    });

    test("get existing display asset", async () => {

        const assetId = "1234";
        const content = "ABCD";
        const contentType = "image/jpeg";

        const { baseUrl, mockAssetDatabase } = await initServer();

        mockAssetDatabase.streamDisplay = () => ({
            contentType,
            stream: stringStream(content),
        });

        const response = await axios.get(`${baseUrl}/display?id=${assetId}`);
        expect(response.status).toBe(200);
        expect(response.headers["content-type"]).toBe(contentType);
        expect(response.data).toEqual(content);
    });

    test("non existing display asset yields a 404 error", async () => {

        const assetId = "1234";
        const { baseUrl, mockAssetDatabase } = await initServer();

        mockAssetDatabase.streamDisplay = async () => undefined;

        const response = await axios.get(`${baseUrl}/display?id=${assetId}`);
        expect(response.status).toBe(404);
    });

    test("get existing display asset with no id yields an error", async () => {

        const { baseUrl } = await initServer();

        const response = await axios.get(`${baseUrl}/display`);
        expect(response.status).toBe(400);
    });

    test("check for existing asset by hash", async () => {

        const assetId = "1234";
        const { baseUrl, mockAssetDatabase } = await initServer();

        mockAssetDatabase.checkAsset = async () => assetId;
        
        const hash = "ABCD";
        const response = await axios.get(`${baseUrl}/check-asset?hash=${hash}`);
        expect(response.status).toBe(200);
        expect(response.data.assetId).toEqual(assetId);
    });

    test("check for non-existing asset by hash", async () => {

        const { baseUrl, mockAssetDatabase } = await initServer();
        
        mockAssetDatabase.checkAsset = async () => undefined;
                    
        const hash = "1234";
        const response = await axios.get(`${baseUrl}/check-asset?hash=${hash}`);
        expect(response.status).toBe(200);
        expect(response.data.assetId).toBeUndefined();
    });

    test("check for existing asset with no hash yields an error", async () => {

        const { baseUrl } = await initServer();

        const response = await axios.get(`${baseUrl}/check-asset`);
        expect(response.status).toBe(400);
    });

    test("can get assets", async () => {

        const { baseUrl, mockAssetDatabase } = await initServer();

        const assetId1 = "1234";
        const mockAsset1: any = {
            contentType: "image/jpeg",
        };

        const assetId = "5678";
        const mockAsset2: any = { 
            contentType: "image/png",
        };

        mockAssetDatabase.getAssets = async () => ({ assets: [ mockAsset1, mockAsset2 ] });

        const response = await axios.get(`${baseUrl}/assets`);
        
        expect(response.status).toBe(200);
        expect(response.data).toEqual({
            assets: [ mockAsset1, mockAsset2 ],
        });
    });

    test("can add label to asset", async () => {

        const { baseUrl, mockAssetDatabase } = await initServer();

        mockAssetDatabase.addLabel = jest.fn();

        const assetId = "1234";
        const label = "A good label";

        const response = await axios.post(
            `${baseUrl}/asset/add-label`, 
            {
                id: assetId,
                label: label,
            }
        );

        expect(response.status).toBe(200);

        expect(mockAssetDatabase.addLabel).toBeCalledTimes(1);
        expect(mockAssetDatabase.addLabel).toHaveBeenCalledWith(assetId, label);
    });

    test("can remove label from asset", async () => {

        const { baseUrl, mockAssetDatabase } = await initServer();

        mockAssetDatabase.removeLabel = jest.fn();

        const assetId = "1234";
        const label = "A good label";
        
        const response = await axios.post(
            `${baseUrl}/asset/remove-label`,
            {
                id: assetId,
                label: label,
            }
        );

        expect(response.status).toBe(200);

        expect(mockAssetDatabase.removeLabel).toBeCalledTimes(1);
        expect(mockAssetDatabase.removeLabel).toHaveBeenCalledWith(assetId, label);
    });

    test("can set description for asset", async () => {

        const { baseUrl, mockAssetDatabase } = await initServer();

        mockAssetDatabase.setDescription = jest.fn();

        const assetId = "1234";
        const description = "A good description";

        const response = await axios.post(
            `${baseUrl}/asset/description`,
            {
                id: assetId,
                description: description,
            }
        );

        expect(response.status).toBe(200);

        expect(mockAssetDatabase.setDescription).toBeCalledTimes(1);
        expect(mockAssetDatabase.setDescription).toHaveBeenCalledWith(assetId, description);
    });
});

