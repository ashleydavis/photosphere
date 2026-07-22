//
// A REST S3 client for the embedded mobile worker, standing in for `@aws-sdk/client-s3`.
//
// The real AWS SDK is engine-incompatible (aws-s3.ts:5-6 framed the SDK redirect as "native-only"),
// so this implements the operations `packages/storage/src/lib/cloud-storage.ts` actually uses
// (ListObjectsV2, HeadObject, GetObject, PutObject, DeleteObject, DeleteObjects, CopyObject, plus
// ranged GET) directly over the `https` shim, returning the SDK-shaped responses CloudStorage reads.
//
// Transport and trust: requests go through the `https` shim's `requestValidated`, which opens the TLS
// connection in "validated" mode (native validates the CA chain and hostname). This module never uses
// the pinned/trust-all path, so an S3 request is validated by construction and cannot silently
// downgrade. Signing is SigV4 (HMAC-SHA256 via the crypto shim's create-hmac). This client emits no
// request-level logging at all, so credentials, the derived signing key, the session token and the
// Authorization header never reach a log line.
//
// Upload is single-PUT only (no multipart yet): S3's single-PUT limit is 5GB, which no thumbnail or
// display asset approaches. Originals can exceed it; that is a recorded known limit, consistent with
// the whole-file memory model the mobile worker already uses.
//

import { Buffer } from "buffer";
import { requestValidated, type IRequestOptions, type IClientResponse } from "./node-https";
import { createHash, createHmac } from "./node-crypto";

//
// S3 credentials, matching the shape `cloud-storage.ts` passes.
//
export interface IS3Credentials {
    // The AWS access key id.
    accessKeyId: string;

    // The AWS secret access key.
    secretAccessKey: string;

    // An optional session token (STS temporary credentials).
    sessionToken?: string;
}

//
// The S3Client constructor options subset CloudStorage passes.
//
export interface IS3ClientConfig {
    // An optional S3-compatible endpoint (MinIO / DigitalOcean Spaces). When absent, AWS is assumed.
    endpoint?: string;

    // The AWS region (e.g. "us-east-1").
    region?: string;

    // The signing credentials.
    credentials?: IS3Credentials;

    // Accepted for API compatibility with the AWS SDK; timeouts are not wired through the shim.
    requestHandler?: unknown;
}

//
// The result of a low-level HTTP round trip.
//
interface IHttpResult {
    // The HTTP status code.
    statusCode: number;

    // The lowercased response headers.
    headers: Record<string, string>;

    // The full response body.
    body: Buffer;
}

//
// A parsed XML element: its tag name, direct child elements, and the concatenated text of its leaf.
//
interface IXmlElement {
    // The element tag name (without namespace prefix handling; S3 uses a default namespace only).
    name: string;

    // Direct child elements in document order.
    children: IXmlElement[];

    // The element's text content (for a leaf element).
    text: string;
}

//
// An S3-shaped error carrying the AWS error `name`/`Code` and an `$metadata.httpStatusCode`, so the
// CloudStorage branches that test `err.name === "NotFound"` / `err.$metadata?.httpStatusCode === 404`
// behave identically to the SDK.
//
export class S3ServiceError extends Error {
    // The AWS error code (e.g. "NoSuchKey", "NotFound", "PreconditionFailed").
    readonly name: string;

    // The SDK-shaped metadata carrying the HTTP status code.
    readonly $metadata: IS3ErrorMetadata;

    //
    // Builds an S3 error from a code, message and HTTP status.
    //
    constructor(code: string, message: string, httpStatusCode: number) {
        super(message);
        this.name = code;
        this.$metadata = { httpStatusCode };
    }
}

//
// The SDK-shaped `$metadata` on an S3 error/response.
//
export interface IS3ErrorMetadata {
    // The HTTP status code of the failed request.
    httpStatusCode: number;
}

//
// The default map export mirrors `import { ... } from "@aws-sdk/client-s3"` (all are also named exports).
//

//
// URI-encodes a string per AWS SigV4 rules: unreserved characters (A-Z a-z 0-9 - _ . ~) pass through;
// everything else is percent-encoded uppercase. Slashes are encoded unless `keepSlashes` is set (used
// for the canonical path, where each segment is encoded but the separators are preserved).
//
export function awsUriEncode(value: string, keepSlashes: boolean): string {
    let encoded = "";
    for (let index = 0; index < value.length; index++) {
        const char = value[index];
        if ((char >= "A" && char <= "Z") || (char >= "a" && char <= "z") || (char >= "0" && char <= "9")
            || char === "-" || char === "_" || char === "." || char === "~") {
            encoded += char;
        }
        else if (char === "/" && keepSlashes) {
            encoded += char;
        }
        else {
            const bytes = Buffer.from(char, "utf8");
            for (let byteIndex = 0; byteIndex < bytes.length; byteIndex++) {
                encoded += "%" + bytes[byteIndex].toString(16).toUpperCase().padStart(2, "0");
            }
        }
    }
    return encoded;
}

//
// Hex SHA-256 of a buffer, via the crypto shim's pure-JS hash.
//
function sha256Hex(data: Buffer): string {
    return createHash("sha256").update(data).digest("hex") as string;
}

//
// HMAC-SHA256 returning raw bytes, via the crypto shim's create-hmac.
//
function hmacSha256(key: Buffer, data: string): Buffer {
    return createHmac("sha256", key).update(data).digest() as Buffer;
}

//
// The input to the SigV4 signer.
//
export interface ISigV4Input {
    // The HTTP method (e.g. "GET", "PUT").
    method: string;

    // The request host (matching the Host header exactly, including a non-default port if present).
    host: string;

    // The canonical request path (each segment already the raw key; encoded by the signer).
    path: string;

    // The query parameters (name to value), signed and sorted by the signer.
    query: Record<string, string>;

    // The headers to sign (lowercased names); host/x-amz-date/x-amz-content-sha256 are added by the signer.
    headers: Record<string, string>;

    // The hex SHA-256 of the request payload.
    payloadHash: string;

    // The AWS region.
    region: string;

    // The AWS service ("s3").
    service: string;

    // The access key id.
    accessKeyId: string;

    // The secret access key.
    secretAccessKey: string;

    // An optional session token.
    sessionToken?: string;

    // The full ISO amz date (YYYYMMDDTHHMMSSZ).
    amzDate: string;

    // The short date stamp (YYYYMMDD).
    dateStamp: string;
}

//
// Computes the SigV4 `Authorization` header value for a request. Exported so it can be unit-tested
// against the published AWS test vectors independently of any HTTP round trip.
//
export function signRequestV4(input: ISigV4Input): string {
    // Canonical headers: the signed headers plus host, x-amz-content-sha256 and x-amz-date, lowercased,
    // trimmed, sorted by name.
    const headersToSign: Record<string, string> = {};
    for (const name of Object.keys(input.headers)) {
        headersToSign[name.toLowerCase()] = input.headers[name].trim();
    }
    headersToSign["host"] = input.host;
    headersToSign["x-amz-content-sha256"] = input.payloadHash;
    headersToSign["x-amz-date"] = input.amzDate;
    if (input.sessionToken) {
        headersToSign["x-amz-security-token"] = input.sessionToken;
    }

    const sortedHeaderNames = Object.keys(headersToSign).sort();
    let canonicalHeaders = "";
    for (const name of sortedHeaderNames) {
        canonicalHeaders += `${name}:${headersToSign[name]}\n`;
    }
    const signedHeaders = sortedHeaderNames.join(";");

    // Canonical query string: encoded names/values sorted by encoded name.
    const queryPairs: string[] = [];
    for (const name of Object.keys(input.query)) {
        queryPairs.push(`${awsUriEncode(name, false)}=${awsUriEncode(input.query[name], false)}`);
    }
    queryPairs.sort();
    const canonicalQueryString = queryPairs.join("&");

    const canonicalUri = awsUriEncode(input.path, true);

    const canonicalRequest = [
        input.method,
        canonicalUri,
        canonicalQueryString,
        canonicalHeaders,
        signedHeaders,
        input.payloadHash,
    ].join("\n");

    const scope = `${input.dateStamp}/${input.region}/${input.service}/aws4_request`;
    const stringToSign = [
        "AWS4-HMAC-SHA256",
        input.amzDate,
        scope,
        sha256Hex(Buffer.from(canonicalRequest, "utf8")),
    ].join("\n");

    const kDate = hmacSha256(Buffer.from("AWS4" + input.secretAccessKey, "utf8"), input.dateStamp);
    const kRegion = hmacSha256(kDate, input.region);
    const kService = hmacSha256(kRegion, input.service);
    const kSigning = hmacSha256(kService, "aws4_request");
    const signature = hmacSha256(kSigning, stringToSign).toString("hex");

    return `AWS4-HMAC-SHA256 Credential=${input.accessKeyId}/${scope}, SignedHeaders=${signedHeaders}, Signature=${signature}`;
}

//
// Minimal XML parser sufficient for S3 list and error responses: builds an element tree, ignoring the
// XML declaration, attributes (S3 uses a default namespace only) and comments. Repeated tags become
// separate sibling elements, which is what ListObjectsV2's Contents/CommonPrefixes need.
//
export function parseXml(xml: string): IXmlElement {
    const root: IXmlElement = { name: "#root", children: [], text: "" };
    const stack: IXmlElement[] = [root];
    let index = 0;

    while (index < xml.length) {
        const lessThan = xml.indexOf("<", index);
        if (lessThan === -1) {
            break;
        }

        // Text between the previous tag and this one belongs to the current element.
        if (lessThan > index) {
            const text = xml.slice(index, lessThan);
            const current = stack[stack.length - 1];
            current.text += decodeXmlEntities(text);
        }

        const greaterThan = xml.indexOf(">", lessThan);
        if (greaterThan === -1) {
            break;
        }

        const tagContent = xml.slice(lessThan + 1, greaterThan);
        index = greaterThan + 1;

        if (tagContent.startsWith("?") || tagContent.startsWith("!")) {
            // XML declaration or comment: skip.
            continue;
        }

        if (tagContent.startsWith("/")) {
            // Closing tag: pop the stack.
            if (stack.length > 1) {
                stack.pop();
            }
            continue;
        }

        const selfClosing = tagContent.endsWith("/");
        const inner = selfClosing ? tagContent.slice(0, -1) : tagContent;
        const spaceIndex = inner.search(/\s/);
        const name = spaceIndex === -1 ? inner : inner.slice(0, spaceIndex);

        const element: IXmlElement = { name, children: [], text: "" };
        stack[stack.length - 1].children.push(element);
        if (!selfClosing) {
            stack.push(element);
        }
    }

    // The document root element is the single top-level child.
    return root.children.length > 0 ? root.children[0] : root;
}

//
// Decodes the XML entities S3 uses in text nodes.
//
function decodeXmlEntities(text: string): string {
    return text
        .replace(/&lt;/g, "<")
        .replace(/&gt;/g, ">")
        .replace(/&quot;/g, "\"")
        .replace(/&apos;/g, "'")
        .replace(/&amp;/g, "&");
}

//
// Returns the first direct child element with the given name, or undefined.
//
function findChild(element: IXmlElement, name: string): IXmlElement | undefined {
    return element.children.find(child => child.name === name);
}

//
// Returns all direct child elements with the given name.
//
function findChildren(element: IXmlElement, name: string): IXmlElement[] {
    return element.children.filter(child => child.name === name);
}

//
// Returns the trimmed text of the first child with the given name, or undefined.
//
function childText(element: IXmlElement, name: string): string | undefined {
    const child = findChild(element, name);
    return child ? child.text.trim() : undefined;
}

//
// An S3 GetObject body, exposing the transform methods CloudStorage reads.
//
class S3ResponseBody {
    //
    // The full object bytes.
    //
    private readonly bytes: Buffer;

    //
    // Builds a body over the given bytes.
    //
    constructor(bytes: Buffer) {
        this.bytes = bytes;
    }

    //
    // Returns the bytes as a Uint8Array (CloudStorage.read / S3RangeReadableStream).
    //
    async transformToByteArray(): Promise<Uint8Array> {
        return new Uint8Array(this.bytes);
    }

    //
    // Returns the bytes decoded as a string (CloudStorage.checkWriteLock).
    //
    async transformToString(encoding?: string): Promise<string> {
        return this.bytes.toString((encoding as BufferEncoding) || "utf8");
    }
}

//
// The ListObjectsV2 response shape CloudStorage reads.
//
export interface IListObjectsV2Output {
    // The object entries under the prefix (files), each with its Key.
    Contents?: IS3ContentEntry[];

    // The common prefixes (subdirectories), each with its Prefix.
    CommonPrefixes?: IS3CommonPrefix[];

    // The continuation token for the next page, when the result was truncated.
    NextContinuationToken?: string;

    // Whether more results remain.
    IsTruncated?: boolean;
}

//
// A single ListObjectsV2 content entry.
//
export interface IS3ContentEntry {
    // The object key.
    Key?: string;
}

//
// A single ListObjectsV2 common prefix.
//
export interface IS3CommonPrefix {
    // The common prefix (a subdirectory path ending in the delimiter).
    Prefix?: string;
}

//
// The HeadObject response shape CloudStorage reads.
//
export interface IHeadObjectOutput {
    // The object content type.
    ContentType?: string;

    // The object content length in bytes.
    ContentLength?: number;

    // The object last-modified time.
    LastModified?: Date;
}

//
// The GetObject response shape CloudStorage reads.
//
export interface IGetObjectOutput {
    // The object body, with the SDK transform methods.
    Body?: S3ResponseBody;

    // The Content-Range header (for a ranged GET), used by S3RangeReadableStream to learn the total size.
    ContentRange?: string;
}

//
// The two-part bucket/key location a command targets.
//
interface IBucketKey {
    // The bucket name.
    Bucket?: string;

    // The object key.
    Key?: string;
}

//
// The ListObjectsV2 command input.
//
interface IListObjectsV2Input {
    Bucket?: string;
    Prefix?: string;
    Delimiter?: string;
    MaxKeys?: number;
    ContinuationToken?: string;
}

//
// The PutObject command input.
//
interface IPutObjectInput {
    Bucket?: string;
    Key?: string;
    Body?: Buffer | Uint8Array;
    ContentType?: string;
    ContentLength?: number;
    IfNoneMatch?: string;
}

//
// The GetObject command input.
//
interface IGetObjectInput {
    Bucket?: string;
    Key?: string;
    Range?: string;
}

//
// The DeleteObjects command input.
//
interface IDeleteObjectsInput {
    Bucket?: string;
    Delete?: IDeleteSpec;
}

//
// The delete specification carried by DeleteObjects.
//
interface IDeleteSpec {
    // The objects to delete.
    Objects: IBucketKey[];
}

//
// The CopyObject command input.
//
interface ICopyObjectInput {
    Bucket?: string;
    Key?: string;
    CopySource?: string;
}

// The command classes below each carry their input and name the operation for S3Client.send.

//
// Lists objects and common prefixes under a prefix (ListObjectsV2).
//
export class ListObjectsV2Command {
    readonly commandName = "ListObjectsV2";
    constructor(readonly input: IListObjectsV2Input) {}
}

//
// Fetches object metadata (HeadObject).
//
export class HeadObjectCommand {
    readonly commandName = "HeadObject";
    constructor(readonly input: IBucketKey) {}
}

//
// Fetches an object, optionally a byte range (GetObject).
//
export class GetObjectCommand {
    readonly commandName = "GetObject";
    constructor(readonly input: IGetObjectInput) {}
}

//
// Uploads an object (PutObject).
//
export class PutObjectCommand {
    readonly commandName = "PutObject";
    constructor(readonly input: IPutObjectInput) {}
}

//
// Deletes a single object (DeleteObject).
//
export class DeleteObjectCommand {
    readonly commandName = "DeleteObject";
    constructor(readonly input: IBucketKey) {}
}

//
// Deletes up to 1000 objects in one request (DeleteObjects).
//
export class DeleteObjectsCommand {
    readonly commandName = "DeleteObjects";
    constructor(readonly input: IDeleteObjectsInput) {}
}

//
// Copies an object server-side (CopyObject).
//
export class CopyObjectCommand {
    readonly commandName = "CopyObject";
    constructor(readonly input: ICopyObjectInput) {}
}

//
// The ListObjectsV2 output type, kept as a value export so a mixed value/type import resolves (matches
// the AWS SDK, whose ListObjectsV2CommandOutput is used both as a type and, here, referenced by name).
//
export class ListObjectsV2CommandOutput {}

//
// The union of command objects S3Client.send accepts.
//
type S3Command =
    | ListObjectsV2Command
    | HeadObjectCommand
    | GetObjectCommand
    | PutObjectCommand
    | DeleteObjectCommand
    | DeleteObjectsCommand
    | CopyObjectCommand;

//
// The resolved endpoint host/port/path-style for a request.
//
interface IEndpoint {
    // The host to connect to and sign.
    host: string;

    // The TCP port.
    port: number;

    // Whether to use path-style addressing (bucket in the path) rather than virtual-hosted.
    pathStyle: boolean;
}

//
// A REST S3 client over the validated-TLS `https` shim. Constructing it is cheap; each `send` performs
// one signed HTTPS request.
//
export class S3Client {
    //
    // The client configuration (endpoint / region / credentials).
    //
    private readonly config: IS3ClientConfig;

    //
    // The resolved region (defaults to us-east-1, matching the AWS SDK).
    //
    private readonly region: string;

    //
    // Builds the client from the SDK-shaped options CloudStorage passes.
    //
    constructor(config: IS3ClientConfig) {
        this.config = config;
        this.region = config.region || "us-east-1";
    }

    //
    // Dispatches a command, returning the SDK-shaped response CloudStorage expects.
    //
    async send(command: S3Command): Promise<IListObjectsV2Output | IHeadObjectOutput | IGetObjectOutput | Record<string, never>> {
        const commandName = (command as { commandName: string }).commandName;
        switch (commandName) {
            case "ListObjectsV2":
                return this.listObjectsV2((command as ListObjectsV2Command).input);
            case "HeadObject":
                return this.headObject((command as HeadObjectCommand).input);
            case "GetObject":
                return this.getObject((command as GetObjectCommand).input);
            case "PutObject":
                return this.putObject((command as PutObjectCommand).input);
            case "DeleteObject":
                return this.deleteObject((command as DeleteObjectCommand).input);
            case "DeleteObjects":
                return this.deleteObjects((command as DeleteObjectsCommand).input);
            case "CopyObject":
                return this.copyObject((command as CopyObjectCommand).input);
            default:
                throw new Error(`Unsupported S3 command: ${commandName}`);
        }
    }

    //
    // Resolves the endpoint host/port and addressing style for a bucket. With an explicit endpoint
    // (MinIO / Spaces) path-style is used; against AWS, virtual-hosted style is used.
    //
    private resolveEndpoint(bucket: string): IEndpoint {
        const endpoint = this.config.endpoint || (typeof process !== "undefined" ? process.env.AWS_ENDPOINT : undefined);
        if (endpoint) {
            const withoutScheme = endpoint.replace(/^https?:\/\//, "");
            const slashIndex = withoutScheme.indexOf("/");
            const authority = slashIndex === -1 ? withoutScheme : withoutScheme.slice(0, slashIndex);
            const colonIndex = authority.indexOf(":");
            const host = colonIndex === -1 ? authority : authority.slice(0, colonIndex);
            const port = colonIndex === -1 ? 443 : parseInt(authority.slice(colonIndex + 1), 10);
            return { host: colonIndex === -1 ? host : `${host}:${port}`, port, pathStyle: true };
        }
        return { host: `${bucket}.s3.${this.region}.amazonaws.com`, port: 443, pathStyle: false };
    }

    //
    // Signs and performs one HTTPS request over the validated-TLS shim, returning the raw HTTP result.
    //
    private async request(method: string, bucket: string, key: string, query: Record<string, string>, body: Buffer, extraHeaders: Record<string, string>): Promise<IHttpResult> {
        const credentials = this.config.credentials;
        if (!credentials) {
            throw new Error("S3 credentials are required in the mobile worker (none were provided).");
        }

        const endpoint = this.resolveEndpoint(bucket);
        const encodedKey = key.split("/").map(segment => awsUriEncode(segment, false)).join("/");
        const path = endpoint.pathStyle
            ? `/${bucket}${encodedKey ? "/" + encodedKey : ""}`
            : `/${encodedKey}`;

        const now = new Date();
        const amzDate = toAmzDate(now);
        const dateStamp = amzDate.slice(0, 8);
        const payloadHash = sha256Hex(body);

        const authorization = signRequestV4({
            method,
            host: endpoint.host,
            path,
            query,
            headers: extraHeaders,
            payloadHash,
            region: this.region,
            service: "s3",
            accessKeyId: credentials.accessKeyId,
            secretAccessKey: credentials.secretAccessKey,
            sessionToken: credentials.sessionToken,
            amzDate,
            dateStamp,
        });

        const queryString = Object.keys(query)
            .sort()
            .map(name => `${awsUriEncode(name, false)}=${awsUriEncode(query[name], false)}`)
            .join("&");
        const fullPath = queryString ? `${path}?${queryString}` : path;

        const headers: Record<string, string | number> = {
            ...extraHeaders,
            "x-amz-content-sha256": payloadHash,
            "x-amz-date": amzDate,
            "Authorization": authorization,
        };
        if (credentials.sessionToken) {
            headers["x-amz-security-token"] = credentials.sessionToken;
        }
        if (body.length > 0) {
            headers["Content-Length"] = body.length;
        }

        const options: IRequestOptions = {
            hostname: endpoint.host.split(":")[0],
            port: endpoint.port,
            path: fullPath,
            method,
            headers,
        };

        return httpRequest(options, body);
    }

    //
    // ListObjectsV2: lists Contents and CommonPrefixes under a prefix.
    //
    private async listObjectsV2(input: IListObjectsV2Input): Promise<IListObjectsV2Output> {
        const query: Record<string, string> = { "list-type": "2" };
        if (input.Prefix !== undefined) {
            query["prefix"] = input.Prefix;
        }
        if (input.Delimiter !== undefined) {
            query["delimiter"] = input.Delimiter;
        }
        if (input.MaxKeys !== undefined) {
            query["max-keys"] = String(input.MaxKeys);
        }
        if (input.ContinuationToken !== undefined) {
            query["continuation-token"] = input.ContinuationToken;
        }

        const result = await this.request("GET", input.Bucket || "", "", query, Buffer.alloc(0), {});
        if (result.statusCode >= 300) {
            throw errorFromResponse(result);
        }

        const root = parseXml(result.body.toString("utf8"));
        const contents: IS3ContentEntry[] = findChildren(root, "Contents").map(entry => {
            const keyText = childText(entry, "Key");
            const content: IS3ContentEntry = {};
            if (keyText !== undefined) {
                content.Key = keyText;
            }
            return content;
        });
        const commonPrefixes: IS3CommonPrefix[] = findChildren(root, "CommonPrefixes").map(entry => {
            const prefixText = childText(entry, "Prefix");
            const commonPrefix: IS3CommonPrefix = {};
            if (prefixText !== undefined) {
                commonPrefix.Prefix = prefixText;
            }
            return commonPrefix;
        });

        const output: IListObjectsV2Output = {};
        if (contents.length > 0) {
            output.Contents = contents;
        }
        if (commonPrefixes.length > 0) {
            output.CommonPrefixes = commonPrefixes;
        }
        const nextToken = childText(root, "NextContinuationToken");
        if (nextToken !== undefined) {
            output.NextContinuationToken = nextToken;
        }
        output.IsTruncated = childText(root, "IsTruncated") === "true";
        return output;
    }

    //
    // HeadObject: returns metadata, or throws a NotFound error on 404.
    //
    private async headObject(input: IBucketKey): Promise<IHeadObjectOutput> {
        const result = await this.request("HEAD", input.Bucket || "", input.Key || "", {}, Buffer.alloc(0), {});
        if (result.statusCode === 404) {
            throw new S3ServiceError("NotFound", "Not Found", 404);
        }
        if (result.statusCode >= 300) {
            throw errorFromResponse(result);
        }
        const output: IHeadObjectOutput = {};
        if (result.headers["content-type"] !== undefined) {
            output.ContentType = result.headers["content-type"];
        }
        if (result.headers["content-length"] !== undefined) {
            output.ContentLength = parseInt(result.headers["content-length"], 10);
        }
        if (result.headers["last-modified"] !== undefined) {
            output.LastModified = new Date(result.headers["last-modified"]);
        }
        return output;
    }

    //
    // GetObject: returns the body (and Content-Range for a ranged GET), or throws NoSuchKey on 404.
    //
    private async getObject(input: IGetObjectInput): Promise<IGetObjectOutput> {
        const extraHeaders: Record<string, string> = {};
        if (input.Range !== undefined) {
            extraHeaders["range"] = input.Range;
        }
        const result = await this.request("GET", input.Bucket || "", input.Key || "", {}, Buffer.alloc(0), extraHeaders);
        if (result.statusCode === 404) {
            throw new S3ServiceError("NoSuchKey", "The specified key does not exist.", 404);
        }
        if (result.statusCode >= 300) {
            throw errorFromResponse(result);
        }
        const output: IGetObjectOutput = { Body: new S3ResponseBody(result.body) };
        if (result.headers["content-range"] !== undefined) {
            output.ContentRange = result.headers["content-range"];
        }
        return output;
    }

    //
    // PutObject: uploads an object (single PUT, no multipart). Honours the IfNoneMatch conditional the
    // write-lock path uses, mapping a 412 to a PreconditionFailed error.
    //
    private async putObject(input: IPutObjectInput): Promise<Record<string, never>> {
        const body = input.Body ? Buffer.from(input.Body) : Buffer.alloc(0);
        const extraHeaders: Record<string, string> = {};
        if (input.ContentType !== undefined) {
            extraHeaders["content-type"] = input.ContentType;
        }
        if (input.IfNoneMatch !== undefined) {
            extraHeaders["if-none-match"] = input.IfNoneMatch;
        }
        const result = await this.request("PUT", input.Bucket || "", input.Key || "", {}, body, extraHeaders);
        if (result.statusCode === 412) {
            throw new S3ServiceError("PreconditionFailed", "At least one of the preconditions you specified did not hold.", 412);
        }
        if (result.statusCode >= 300) {
            throw errorFromResponse(result);
        }
        return {};
    }

    //
    // DeleteObject: deletes a single object.
    //
    private async deleteObject(input: IBucketKey): Promise<Record<string, never>> {
        const result = await this.request("DELETE", input.Bucket || "", input.Key || "", {}, Buffer.alloc(0), {});
        if (result.statusCode >= 300 && result.statusCode !== 404) {
            throw errorFromResponse(result);
        }
        return {};
    }

    //
    // DeleteObjects: batch-deletes up to 1000 objects with a signed XML body and its Content-MD5.
    //
    private async deleteObjects(input: IDeleteObjectsInput): Promise<Record<string, never>> {
        const objects = input.Delete ? input.Delete.Objects : [];
        let xml = "<Delete>";
        for (const object of objects) {
            xml += `<Object><Key>${escapeXml(object.Key || "")}</Key></Object>`;
        }
        xml += "</Delete>";
        const body = Buffer.from(xml, "utf8");
        const contentMd5 = createHash("md5").update(body).digest("base64") as string;
        const result = await this.request("POST", input.Bucket || "", "", { "delete": "" }, body, {
            "content-type": "application/xml",
            "content-md5": contentMd5,
        });
        if (result.statusCode >= 300) {
            throw errorFromResponse(result);
        }
        return {};
    }

    //
    // CopyObject: server-side copy via the x-amz-copy-source header.
    //
    private async copyObject(input: ICopyObjectInput): Promise<Record<string, never>> {
        const copySource = input.CopySource || "";
        const encodedSource = "/" + copySource.split("/").map(segment => awsUriEncode(segment, false)).join("/");
        const result = await this.request("PUT", input.Bucket || "", input.Key || "", {}, Buffer.alloc(0), {
            "x-amz-copy-source": encodedSource,
        });
        if (result.statusCode >= 300) {
            throw errorFromResponse(result);
        }
        return {};
    }
}

//
// Formats a Date as the SigV4 amz date (YYYYMMDDTHHMMSSZ, UTC).
//
function toAmzDate(date: Date): string {
    const pad = (value: number): string => value.toString().padStart(2, "0");
    return `${date.getUTCFullYear()}${pad(date.getUTCMonth() + 1)}${pad(date.getUTCDate())}T${pad(date.getUTCHours())}${pad(date.getUTCMinutes())}${pad(date.getUTCSeconds())}Z`;
}

//
// Escapes XML text for the DeleteObjects body.
//
function escapeXml(value: string): string {
    return value
        .replace(/&/g, "&amp;")
        .replace(/</g, "&lt;")
        .replace(/>/g, "&gt;");
}

//
// Builds an S3ServiceError from a non-2xx HTTP result, reading the AWS error XML <Code>/<Message> when
// present so callers see the same error `name` the SDK would surface.
//
function errorFromResponse(result: IHttpResult): S3ServiceError {
    let code = `HTTP${result.statusCode}`;
    let message = `S3 request failed with status ${result.statusCode}`;
    const text = result.body.toString("utf8").trim();
    if (text.startsWith("<")) {
        const root = parseXml(text);
        const parsedCode = childText(root, "Code");
        const parsedMessage = childText(root, "Message");
        if (parsedCode) {
            code = parsedCode;
        }
        if (parsedMessage) {
            message = parsedMessage;
        }
    }
    return new S3ServiceError(code, message, result.statusCode);
}

//
// Performs one HTTPS request over the validated-TLS shim and buffers the whole response. The TLS
// connection is opened in "validated" mode by `requestValidated`; a native certificate-validation
// failure surfaces as a thrown error here (rejecting the promise), so a bad certificate fails closed
// rather than silently returning an empty result.
//
function httpRequest(options: IRequestOptions, body: Buffer): Promise<IHttpResult> {
    return new Promise<IHttpResult>((resolve, reject) => {
        const clientRequest = requestValidated(options, (response: IClientResponse) => {
            const chunks: Buffer[] = [];
            response.on("data", (chunk: Buffer) => {
                chunks.push(chunk);
            });
            response.on("end", () => {
                resolve({ statusCode: response.statusCode, headers: response.headers, body: Buffer.concat(chunks) });
            });
        });
        clientRequest.on("error", (error: Error) => {
            reject(error);
        });
        if (body.length > 0) {
            clientRequest.write(body);
        }
        clientRequest.end();
    });
}

//
// The default export mirrors `import S3 from "@aws-sdk/client-s3"` for any default-import consumer.
//
const s3Module = {
    S3Client,
    ListObjectsV2Command,
    HeadObjectCommand,
    GetObjectCommand,
    PutObjectCommand,
    DeleteObjectCommand,
    DeleteObjectsCommand,
    CopyObjectCommand,
    ListObjectsV2CommandOutput,
    signRequestV4,
    parseXml,
    awsUriEncode,
};

export default s3Module;
