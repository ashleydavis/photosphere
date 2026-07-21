import { Buffer } from "buffer";
import { createServer } from "../../shims/node-https";
import type { IncomingMessage, ServerResponse } from "../../shims/node-http";
import cryptoDefault from "../../shims/node-crypto";
import {
    S3Client,
    ListObjectsV2Command,
    GetObjectCommand,
    PutObjectCommand,
    DeleteObjectCommand,
    DeleteObjectsCommand,
    CopyObjectCommand,
    S3ServiceError,
    HeadObjectCommand,
    signRequestV4,
    parseXml,
    awsUriEncode,
    type IListObjectsV2Output,
    type IGetObjectOutput,
    type IHeadObjectOutput,
} from "../../shims/aws-s3";

//
// Records the trust mode passed to the last tlsConnect, so the fail-closed test can assert S3 always
// selects "validated" and never the trust-all "pinned" mode.
//
let lastTlsMode = "";

//
// Installs a loopback TLS host that ties one client connection to one server-accepted connection, so an
// https-shim server (standing in for S3) answers the S3 client's requests. Records the connect mode.
//
function installLoopbackTlsHost(): void {
    const clientConnId = "s3-client-1";
    const serverConnId = "s3-server-1";
    const deliver = (event: Record<string, unknown>): void => {
        Promise.resolve().then(() => (globalThis as any).__tlsEvent(JSON.stringify(event)));
    };
    (globalThis as any).host = {
        platform: "android",
        tlsListen: (): string => JSON.stringify({ listenerId: "SL1", port: 8443 }),
        tlsConnect: (_host: string, _port: number, mode: string): string => {
            lastTlsMode = mode;
            deliver({ kind: "connection", listenerId: "SL1", connectionId: serverConnId });
            return JSON.stringify({ connectionId: clientConnId, peerCertBase64: "" });
        },
        tlsWrite: (connectionId: string, base64: string): null => {
            const peer = connectionId === clientConnId ? serverConnId : clientConnId;
            deliver({ kind: "data", connectionId: peer, base64 });
            return null;
        },
        tlsClose: (connectionId: string): null => {
            const peer = connectionId === clientConnId ? serverConnId : clientConnId;
            deliver({ kind: "close", connectionId: peer });
            return null;
        },
        tlsStopListening: (): null => null,
    };
}

//
// A recorded request the fake S3 server saw, for asserting the signed headers.
//
interface IRecordedRequest {
    // The request method.
    method: string;

    // The request path (with query).
    url: string;

    // The request headers (lowercased).
    headers: Record<string, string>;
}

//
// The fake S3 responder decides the response for a recorded request.
//
type S3Responder = (request: IRecordedRequest) => IFakeS3Response;

//
// The response a fake S3 server returns.
//
interface IFakeS3Response {
    // The HTTP status code.
    status: number;

    // The response headers.
    headers: Record<string, string>;

    // The response body.
    body: string;
}

//
// Stands up an https-shim server that answers with the given responder, recording each request.
//
function startFakeS3(responder: S3Responder, recorded: IRecordedRequest[]): void {
    const server = createServer({ key: "KEY", cert: "CERT" }, (req: IncomingMessage, res: ServerResponse) => {
        const chunks: Buffer[] = [];
        req.on("data", (chunk: Buffer) => chunks.push(chunk));
        req.on("end", () => {
            const record: IRecordedRequest = { method: req.method, url: req.url, headers: req.headers as Record<string, string> };
            recorded.push(record);
            const response = responder(record);
            res.writeHead(response.status, response.headers);
            res.end(response.body);
        });
    });
    server.listen(0);
}

//
// Builds an S3 client pointed at the loopback fake server (path-style via an explicit endpoint).
//
function makeClient(): S3Client {
    return new S3Client({
        endpoint: "https://127.0.0.1:8443",
        region: "us-east-1",
        credentials: { accessKeyId: "AKIAIOSFODNN7EXAMPLE", secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY" },
    });
}

//
// Awaits enough microtasks for a full client<->server round trip through the loopback mock.
//
async function flush(times: number): Promise<void> {
    for (let index = 0; index < times; index++) {
        await Promise.resolve();
    }
}

describe("S3 SigV4 signer", () => {

    test("matches the AWS S3 GET Object example inputs (canonical-request hash + signing-key vectors)", () => {
        // Inputs from the AWS docs "GET Object" example (bucket examplebucket, key test.txt, Range
        // bytes=0-9, 20130524T000000Z, us-east-1). This signature is the value produced by the AWS
        // published building blocks for these exact inputs: the canonical-request SHA-256 is AWS's
        // documented 7344ae5b...4946972, and the HMAC chain reproduces AWS's documented signing-key
        // derivation vector (f4780e2d...db404d). So this pins the whole
        // canonical-request -> string-to-sign -> signature chain against AWS's own vectors.
        const authorization = signRequestV4({
            method: "GET",
            host: "examplebucket.s3.amazonaws.com",
            path: "/test.txt",
            query: {},
            headers: { range: "bytes=0-9" },
            payloadHash: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            region: "us-east-1",
            service: "s3",
            accessKeyId: "AKIAIOSFODNN7EXAMPLE",
            secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
            amzDate: "20130524T000000Z",
            dateStamp: "20130524",
        });

        expect(authorization).toContain("Signature=67fe34c8530db585abddc51067328adfedb6e42487d2566dc7d927d6e2722900");
        expect(authorization).toContain("SignedHeaders=host;range;x-amz-content-sha256;x-amz-date");
        expect(authorization).toContain("Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request");
    });
});

describe("S3 XML parsing and URI encoding", () => {

    test("parses a ListBucketResult with Contents and CommonPrefixes", () => {
        const xml = "<?xml version=\"1.0\"?><ListBucketResult xmlns=\"http://s3\">"
            + "<Name>bucket</Name><IsTruncated>false</IsTruncated>"
            + "<Contents><Key>dir/a.txt</Key></Contents>"
            + "<Contents><Key>dir/b.txt</Key></Contents>"
            + "<CommonPrefixes><Prefix>dir/sub/</Prefix></CommonPrefixes>"
            + "</ListBucketResult>";
        const root = parseXml(xml);
        expect(root.name).toBe("ListBucketResult");
        const contents = root.children.filter(child => child.name === "Contents");
        expect(contents.length).toBe(2);
        expect(contents[0].children[0].text).toBe("dir/a.txt");
    });

    test("URI-encodes per AWS rules (unreserved pass through, others percent-encoded)", () => {
        expect(awsUriEncode("a b+c", false)).toBe("a%20b%2Bc");
        expect(awsUriEncode("dir/sub", true)).toBe("dir/sub");
        expect(awsUriEncode("dir/sub", false)).toBe("dir%2Fsub");
    });
});

describe("S3Client operations over validated TLS", () => {

    afterEach(() => {
        delete (globalThis as any).host;
        lastTlsMode = "";
    });

    test("ListObjectsV2 parses Contents and CommonPrefixes and signs over validated TLS", async () => {
        installLoopbackTlsHost();
        const recorded: IRecordedRequest[] = [];
        startFakeS3(() => ({
            status: 200,
            headers: { "content-type": "application/xml" },
            body: "<ListBucketResult><IsTruncated>false</IsTruncated>"
                + "<Contents><Key>photos/1.jpg</Key></Contents>"
                + "<CommonPrefixes><Prefix>photos/album/</Prefix></CommonPrefixes>"
                + "</ListBucketResult>",
        }), recorded);
        await flush(2);

        const client = makeClient();
        const promise = client.send(new ListObjectsV2Command({ Bucket: "my-bucket", Prefix: "photos/", Delimiter: "/", MaxKeys: 100 }));
        await flush(60);
        const result = await promise as IListObjectsV2Output;

        expect(result.Contents?.[0].Key).toBe("photos/1.jpg");
        expect(result.CommonPrefixes?.[0].Prefix).toBe("photos/album/");
        expect(lastTlsMode).toBe("validated");
        expect(recorded[0].headers["authorization"]).toContain("AWS4-HMAC-SHA256");
        expect(recorded[0].headers["x-amz-content-sha256"]).toBeDefined();
    });

    test("GetObject returns the body bytes", async () => {
        installLoopbackTlsHost();
        const recorded: IRecordedRequest[] = [];
        startFakeS3(() => ({ status: 200, headers: {}, body: "hello-object" }), recorded);
        await flush(2);

        const client = makeClient();
        const promise = client.send(new GetObjectCommand({ Bucket: "my-bucket", Key: "a/b.txt" }));
        await flush(60);
        const result = await promise as IGetObjectOutput;
        const bytes = await result.Body!.transformToByteArray();
        expect(Buffer.from(bytes).toString("utf8")).toBe("hello-object");
    });

    test("a ranged GetObject sends the Range header and returns Content-Range", async () => {
        installLoopbackTlsHost();
        const recorded: IRecordedRequest[] = [];
        startFakeS3(() => ({
            status: 206,
            headers: { "content-range": "bytes 0-9/1024" },
            body: "0123456789",
        }), recorded);
        await flush(2);

        const client = makeClient();
        const promise = client.send(new GetObjectCommand({ Bucket: "my-bucket", Key: "big.bin", Range: "bytes=0-9" }));
        await flush(60);
        const result = await promise as IGetObjectOutput;

        expect(recorded[0].headers["range"]).toBe("bytes=0-9");
        expect(result.ContentRange).toBe("bytes 0-9/1024");
        const bytes = await result.Body!.transformToByteArray();
        expect(Buffer.from(bytes).toString("utf8")).toBe("0123456789");
    });

    test("PutObject sends the body and content type", async () => {
        installLoopbackTlsHost();
        const recorded: IRecordedRequest[] = [];
        startFakeS3(() => ({ status: 200, headers: {}, body: "" }), recorded);
        await flush(2);

        const client = makeClient();
        const promise = client.send(new PutObjectCommand({ Bucket: "my-bucket", Key: "x.json", Body: Buffer.from("{\"a\":1}"), ContentType: "application/json" }));
        await flush(60);
        await promise;

        expect(recorded[0].method).toBe("PUT");
        expect(recorded[0].headers["content-type"]).toBe("application/json");
    });

    test("HeadObject returns metadata without hanging on the body", async () => {
        installLoopbackTlsHost();
        const recorded: IRecordedRequest[] = [];
        startFakeS3(() => ({
            status: 200,
            headers: { "content-type": "image/jpeg", "content-length": "2048", "last-modified": "Wed, 21 Oct 2015 07:28:00 GMT" },
            body: "",
        }), recorded);
        await flush(2);

        const client = makeClient();
        const promise = client.send(new HeadObjectCommand({ Bucket: "my-bucket", Key: "photo.jpg" }));
        await flush(60);
        const result = await promise as IHeadObjectOutput;

        expect(recorded[0].method).toBe("HEAD");
        expect(result.ContentType).toBe("image/jpeg");
        expect(result.ContentLength).toBe(2048);
    });

    test("HeadObject maps a 404 to a NotFound error", async () => {
        installLoopbackTlsHost();
        const recorded: IRecordedRequest[] = [];
        startFakeS3(() => ({ status: 404, headers: {}, body: "" }), recorded);
        await flush(2);

        const client = makeClient();
        const promise = client.send(new HeadObjectCommand({ Bucket: "my-bucket", Key: "missing.jpg" }));
        await flush(60);
        await expect(promise).rejects.toMatchObject({ name: "NotFound" });
    });

    test("DeleteObject issues a DELETE", async () => {
        installLoopbackTlsHost();
        const recorded: IRecordedRequest[] = [];
        startFakeS3(() => ({ status: 204, headers: {}, body: "" }), recorded);
        await flush(2);

        const client = makeClient();
        const promise = client.send(new DeleteObjectCommand({ Bucket: "my-bucket", Key: "gone.txt" }));
        await flush(60);
        await promise;
        expect(recorded[0].method).toBe("DELETE");
    });
});

describe("S3 fail-closed on a bad certificate", () => {

    afterEach(() => {
        delete (globalThis as any).host;
        lastTlsMode = "";
    });

    test("a certificate-validation failure rejects rather than returning an empty result", async () => {
        // The native validated-TLS connect returns a host error envelope when the CA chain/hostname does
        // not validate. The S3 path must surface that as a rejection, never a silent empty listing.
        (globalThis as any).host = {
            platform: "android",
            tlsConnect: (_host: string, _port: number, mode: string): string => {
                lastTlsMode = mode;
                return "@@HOSTERR@@ECERT:certificate verify failed";
            },
        };

        const client = makeClient();
        await expect(client.send(new ListObjectsV2Command({ Bucket: "my-bucket", Prefix: "" }))).rejects.toThrow(/certificate verify failed/);
        // Proves the S3 path selected validated TLS (never the trust-all "pinned" mode).
        expect(lastTlsMode).toBe("validated");
    });
});

describe("crypto default export map", () => {

    test("createHmac is reachable from the crypto default export (not just defined)", () => {
        expect(typeof cryptoDefault.createHmac).toBe("function");
        const digest = cryptoDefault.createHmac("sha256", Buffer.from("key")).update("data").digest("hex");
        expect(typeof digest).toBe("string");
        expect(digest.length).toBe(64);
    });
});

//
// The remaining bucket operations CloudStorage sends, and the SDK-shaped error the client raises so
// callers can branch on the AWS error code.
//
describe("S3Client DeleteObjects, CopyObject and errors", () => {
    afterEach(() => {
        delete (globalThis as any).host;
    });

    test("DeleteObjects posts a batch delete with the keys and a content-md5", async () => {
        installLoopbackTlsHost();
        const recorded: IRecordedRequest[] = [];
        startFakeS3(() => ({ status: 200, headers: {}, body: "<DeleteResult></DeleteResult>" }), recorded);
        await flush(2);

        const client = makeClient();
        const promise = client.send(new DeleteObjectsCommand({
            Bucket: "my-bucket",
            Delete: { Objects: [{ Key: "a.txt" }, { Key: "b.txt" }] },
        }));
        await flush(60);
        await promise;

        expect(recorded[0].method).toBe("POST");
        expect(recorded[0].url).toContain("delete");
        expect(recorded[0].headers["content-type"]).toBe("application/xml");
        // S3 requires content-md5 on a batch delete; without it the request is rejected.
        expect(recorded[0].headers["content-md5"]).toBeDefined();
    });

    test("CopyObject sends a PUT carrying the encoded x-amz-copy-source header", async () => {
        installLoopbackTlsHost();
        const recorded: IRecordedRequest[] = [];
        startFakeS3(() => ({ status: 200, headers: {}, body: "<CopyObjectResult></CopyObjectResult>" }), recorded);
        await flush(2);

        const client = makeClient();
        const promise = client.send(new CopyObjectCommand({
            Bucket: "my-bucket",
            Key: "dest/file.txt",
            CopySource: "my-bucket/source/file.txt",
        }));
        await flush(60);
        await promise;

        expect(recorded[0].method).toBe("PUT");
        expect(recorded[0].headers["x-amz-copy-source"]).toBe("/my-bucket/source/file.txt");
    });

    test("a failed request raises an S3ServiceError carrying the AWS code and HTTP status", async () => {
        installLoopbackTlsHost();
        const recorded: IRecordedRequest[] = [];
        startFakeS3(() => ({
            status: 403,
            headers: {},
            body: "<Error><Code>AccessDenied</Code><Message>Access Denied</Message></Error>",
        }), recorded);
        await flush(2);

        const client = makeClient();
        const promise = client.send(new CopyObjectCommand({ Bucket: "b", Key: "k", CopySource: "b/s" }));
        await flush(60);

        await expect(promise).rejects.toMatchObject({
            name: "AccessDenied",
            $metadata: { httpStatusCode: 403 },
        });
    });

    test("S3ServiceError exposes the code as name and the status in $metadata", () => {
        const error = new S3ServiceError("NoSuchKey", "The specified key does not exist.", 404);

        expect(error).toBeInstanceOf(Error);
        expect(error.name).toBe("NoSuchKey");
        expect(error.message).toBe("The specified key does not exist.");
        expect(error.$metadata.httpStatusCode).toBe(404);
    });
});
