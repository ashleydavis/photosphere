import { Buffer } from "buffer";
import { Readable } from "stream";
import express from "express";
import { attachAssetServerRoutes } from "node-api/src/lib/asset-server-routes";
import type { IAssetServerCore } from "node-api/src/lib/asset-server-core";
import { createServer } from "../../shims/node-http";
import { installMockTcpHost, uninstallMockTcpHost, roundTripRequest } from "./tcp-mock-host";

//
// The seeded asset bytes the test core serves, keyed by `${type}/${id}`.
//
const SEEDED_ASSETS: Record<string, Buffer> = {
    "thumb/asset-1": Buffer.from("thumb-bytes-1"),
    "display/asset-1": Buffer.from("display-bytes-1"),
    "asset/asset-1": Buffer.from("full-bytes-1"),
};

//
// Parses the numeric status code from a raw HTTP response.
//
function statusOf(responseBytes: Buffer): number {
    const firstLine = responseBytes.toString("utf8").split("\r\n")[0];
    return parseInt(firstLine.split(" ")[1], 10);
}

//
// Extracts the response body (bytes after the blank line) from a raw HTTP response.
//
function bodyOf(responseBytes: Buffer): Buffer {
    const separator = responseBytes.indexOf("\r\n\r\n");
    return responseBytes.subarray(separator + 4);
}

describe("asset server over the shimmed http", () => {
    let writeAsset: jest.Mock;
    let applyDatabaseOps: jest.Mock;

    //
    // Builds an express app with the asset routes attached over a test core, served by the http shim.
    //
    function startServer(): void {
        writeAsset = jest.fn().mockResolvedValue(undefined);
        applyDatabaseOps = jest.fn().mockResolvedValue(undefined);
        const core: IAssetServerCore = {
            serveAsset: async (assetId: string, assetType: string) => {
                const bytes = SEEDED_ASSETS[`${assetType}/${assetId}`];
                if (!bytes) {
                    throw new Error("not found");
                }
                return Readable.from([bytes]);
            },
            writeAsset: writeAsset as unknown as IAssetServerCore["writeAsset"],
            applyDatabaseOps: applyDatabaseOps as unknown as IAssetServerCore["applyDatabaseOps"],
        };

        const app = express();
        attachAssetServerRoutes(app, core, true);
        const server = createServer(app as unknown as (req: any, res: any) => void);
        server.listen(0, "127.0.0.1");
    }

    afterEach(() => {
        uninstallMockTcpHost();
    });

    test("GET /asset returns the seeded bytes for thumb", async () => {
        const mock = installMockTcpHost("L-asset-1", 8080);
        startServer();

        const request = Buffer.from("GET /asset?id=asset-1&type=thumb&db=%2Fdb HTTP/1.1\r\nContent-Length: 0\r\n\r\n");
        const response = await roundTripRequest(mock, request);

        expect(statusOf(response)).toBe(200);
        expect(bodyOf(response).toString()).toBe("thumb-bytes-1");
    });

    test("GET /asset returns 400 when id is missing", async () => {
        const mock = installMockTcpHost("L-asset-2", 8080);
        startServer();

        const request = Buffer.from("GET /asset?type=thumb&db=%2Fdb HTTP/1.1\r\nContent-Length: 0\r\n\r\n");
        const response = await roundTripRequest(mock, request);

        expect(statusOf(response)).toBe(400);
    });

    // The gallery EDIT path. This is the one route the UI uses to change a record, and unlike
    // GET /asset and POST /asset it parses its body with express.json(), so it is the only place the
    // shim's readable surface has to satisfy body-parser and raw-body rather than being consumed
    // directly. Asserting the ops reach the core is the whole point: an earlier version of this test
    // checked only that a framed HTTP response came back, which a 400 from a body that never arrived
    // satisfies just as well as a 204 from one that did.
    test("POST /apply-database-ops delivers the parsed ops to the core", async () => {
        const mock = installMockTcpHost("L-asset-3", 8080);
        startServer();

        const ops = [{ databaseId: "/db", collectionName: "metadata", recordId: "asset-1", op: { type: "set", fields: { description: "edited" } } }];
        const payload = JSON.stringify({ ops });
        const request = Buffer.from(`POST /apply-database-ops HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: ${Buffer.byteLength(payload)}\r\n\r\n${payload}`);
        const response = await roundTripRequest(mock, request);

        expect(statusOf(response)).toBe(204);
        expect(applyDatabaseOps).toHaveBeenCalledTimes(1);
        expect(applyDatabaseOps).toHaveBeenCalledWith(ops);
    });

    test("POST /asset writes the asset and returns 204", async () => {
        const mock = installMockTcpHost("L-asset-4", 8080);
        startServer();

        const payload = "raw-asset-bytes";
        const request = Buffer.from(`POST /asset?id=asset-1&type=thumb&db=%2Fdb HTTP/1.1\r\nContent-Type: image/jpeg\r\nContent-Length: ${payload.length}\r\n\r\n${payload}`);
        const response = await roundTripRequest(mock, request);

        expect(statusOf(response)).toBe(204);
        expect(writeAsset).toHaveBeenCalledTimes(1);
        expect(writeAsset).toHaveBeenCalledWith("asset-1", "thumb", "/db", "image/jpeg", expect.anything(), expect.anything());
    });
});
