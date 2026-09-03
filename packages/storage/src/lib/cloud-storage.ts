import { Readable } from "stream";
import {
    S3Client,
    ListObjectsV2Command,
    HeadObjectCommand,
    GetObjectCommand,
    PutObjectCommand,
    DeleteObjectCommand,
    DeleteObjectsCommand,
    CopyObjectCommand,
    ListObjectsV2CommandOutput,
} from "@aws-sdk/client-s3";
import { HttpRequest } from "@smithy/protocol-http";
import { S3RangeReadableStream } from "./s3-range-readable-stream";
import { parseS3ListPath } from "./s3-path";
import { Upload } from "@aws-sdk/lib-storage";
import { IFileInfo, IListResult, IStorage, IWriteLockInfo } from "./storage";
import { WrappedError } from "utils";
import { log } from "utils";

// Write lock timeout in milliseconds (10 seconds)
const WRITE_LOCK_TIMEOUT_MS = 10000;

//
// How much of an upload goes in one part.
//
// The uploader holds a whole part in memory before it sends any of it, so the part size is how much
// memory an upload costs and how long it is silent before bytes start moving. At 100MB, which this
// was, a 100MB video on a Pixel 6 sat at full CPU for twenty minutes with nothing reaching the
// server while the engine assembled the part.
//
// Five megabytes, which is the smallest S3 allows: anything under it is refused outright with
// "EntityTooSmall: Your proposed upload part size is smaller than the minimum allowed size". It
// still allows a 2GB file, which is 400 parts against the 10,000 S3 permits.
//
// The smallest is what is wanted here, because a part is held in memory before it is sent and is one
// request against the server's own object lock. A phone pushes about seven megabytes a minute, so
// eight megabyte parts took over a minute each and MinIO refused the one after with "A timeout
// occurred while trying to lock a resource, please reduce your request rate", over and over on the
// same video.
//
const UPLOAD_PART_BYTES = 5 * 1024 * 1024;

//
// The largest body still sent as one request, and so the largest that can carry a whole-object
// checksum for the server to check it against.
//
// A multipart upload's checksum is a hash of its parts' hashes rather than a hash of the object, so
// it cannot be compared with the hash the database holds. Sending a whole object in one request also
// keeps it out of the multipart machinery entirely, which is where syncing a phone's library kept
// failing: parts lost their ETag, and then the server refused them with "A timeout occurred while
// trying to lock a resource, please reduce your request rate" part way through a video.
//
// A gigabyte, so that every file a phone library holds goes up whole, which is the only way it goes
// up quickly.
//
// A multipart upload cannot be handed a file. The uploader reads the stream into a buffer per part,
// and on a phone the bytes reach a buffer only by crossing the host bridge as base64, a third larger
// than what they carry, decoded in an interpreter, and then crossing it again on the way out. One
// request per file keeps the stream file-backed all the way down, and the mobile shims then have the
// file sent from disk to the socket natively, never entering the engine at all.
//
// Measured on a Pixel 6 syncing a real library over WiFi to MinIO on the same LAN, with the network
// itself proven to carry 11.8MB/s from that phone: files under the old eight megabyte ceiling went
// up in under a second each, and every part of every larger file took 2.2 to 2.5 seconds to send
// five megabytes, about 2.2MB/s, with roughly as long again spent reading the part in before the
// request even started. Three videos and seventeen photos took 153 seconds, of which the videos were
// nearly all of it.
//
// Eight megabytes was the old ceiling, on the reasoning that a single large request holds the
// server's lock on the object for as long as it takes and MinIO refuses one that takes too long.
// That did happen, repeatedly, and it was not the length of the request: a defect in the HTTP shim
// sent some requests with no body at all, so the server sat holding its lock waiting for bytes that
// were never coming. With that fixed and the file sent natively, a 79MB video is a seven second
// request rather than an eleven minute one.
//
// Above this the multipart uploader still runs, so a file too large for one request has a path, and
// S3's own limit on a single PUT is five gigabytes.
//
const SINGLE_PART_MAX_BYTES = 1024 * 1024 * 1024;

//
// S3 credentials.
//
export interface IS3Credentials {
    accessKeyId: string;
    secretAccessKey: string;
    region?: string;
    endpoint?: string;
}

/*
AWS S3:
- https://docs.aws.amazon.com/sdkref/latest/guide/environment-variables.html
- https://docs.aws.amazon.com/sdk-for-javascript/v2/developer-guide/loading-node-credentials-environment.html
- https://docs.aws.amazon.com/AWSJavaScriptSDK/v3/latest/index.html
- https://docs.aws.amazon.com/AWSJavaScriptSDK/v3/latest/clients/client-s3/index.html
- https://docs.aws.amazon.com/sdk-for-javascript/v3/developer-guide/getting-started-nodejs.html

Digital Ocean Spaces:
- https://docs.digitalocean.com/reference/api/spaces-api/
- https://docs.digitalocean.com/products/spaces/reference/s3-sdk-examples/

*/

export class CloudStorage implements IStorage {
    
    //
    // AWS S3 client.
    //
    private s3!: S3Client;

    constructor(public readonly location: string, credentials?: IS3Credentials) {
        const endpoint = credentials?.endpoint || process.env.AWS_ENDPOINT;

        this.s3 = this.buildClient(endpoint, credentials);
    }

    //
    // Builds the S3 client, and tells the signer not to hash request bodies.
    //
    // Signature version 4 normally covers the body: the signer reads the whole request payload and
    // puts its SHA-256 in x-amz-content-sha256. The SDK skips that of its own accord over HTTPS,
    // where it sends UNSIGNED-PAYLOAD instead, and does not over plain HTTP, which is what an S3
    // server on a local network is reached over.
    //
    // On a phone that hash is the single most expensive thing a sync does. It runs in the embedded
    // engine's pure JavaScript SHA-256 at well under a megabyte a second: measured on a Pixel 6, a
    // 100MB video held one upload for over twenty minutes at full CPU without a byte reaching the
    // server. Nothing is given up by not signing the body, because every file this writes carries a
    // SHA-256 the server checks it against (see writeStreamHashed), which the signature never did.
    //
    private buildClient(endpoint: string | undefined, credentials: IS3Credentials | undefined): S3Client {
        const client = new S3Client({
            ...(endpoint && { endpoint }),

            // One attempt per request, and no more.
            //
            // The SDK's own retries are meant for a request that failed and is over. An upload from a
            // phone is neither: it takes minutes, and a retry started while the first attempt is
            // still streaming has two requests writing one object, which the server refuses with "A
            // timeout occurred while trying to lock a resource, please reduce your request rate".
            // Retrying is done above this, by the caller, one attempt at a time.
            maxAttempts: 1,
            requestHandler: {
                // Ten minutes for one request, not thirty seconds.
                //
                // Thirty seconds is a sensible ceiling on a desktop and far too short on a phone: a
                // Pixel 6 pushes about seven megabytes a minute through the engine bridge, so a
                // single eight megabyte upload part takes over a minute. Every large file failed
                // with "Operation timed out after 30000ms", was retried, and failed again, so a
                // library with a video in it never finished syncing.
                //
                // It is still a ceiling, so a connection that has died is still given up on rather
                // than waited on for ever.
                requestTimeout: 600000,

                // Five minutes to get a connection, not ten seconds.
                //
                // Ten seconds assumes the wait is the network's. In the embedded engine it is not:
                // everything runs on one JavaScript thread, and the timer that gives up on the
                // connection is on that same thread. While the thread is carrying a part of an upload
                // across the host bridge it services neither, and when it comes free the timer fires
                // for time that was never spent connecting. Syncing a real library from a Pixel 6
                // failed on a large video with "the request socket did not establish a connection
                // with the server within the configured timeout of 10000 ms", and then the same at
                // 60000 ms, against a server on the same desk answering everything else in
                // milliseconds.
                //
                // It remains a ceiling: a server that is really unreachable fails the request anyway,
                // through the connect the native side gives up on after ten seconds.
                connectionTimeout: 300000,
            },
            ...(credentials && {
                credentials: {
                    accessKeyId: credentials.accessKeyId,
                    secretAccessKey: credentials.secretAccessKey,
                },
                ...(credentials.region && { region: credentials.region }),
            }),
        });

        // Added before signing rather than after it: the signer uses the value of this header as the
        // payload hash when one is already there, and hashes the body itself when it is not.
        client.middlewareStack.addRelativeTo(
            (next: any) => async (args: any) => {
                if (HttpRequest.isInstance(args.request) && args.request.body !== undefined) {
                    args.request.headers["x-amz-content-sha256"] = "UNSIGNED-PAYLOAD";
                }
                return next(args);
            },
            {
                relation: "before",
                toMiddleware: "awsAuthMiddleware",
                name: "photosphereUnsignedPayload",
            });

        return client;
    }

    //
    // Parse the path and extract the bucket and key.
    //
    private parsePath(path: string): { bucket: string, key: string } {
        const slashIndex = path.indexOf("/");
        if (slashIndex === -1) {
            throw new Error(`Invalid path: ${path}. Expected <bucket-name>/<path>`);
        }
        
        const bucket = path.slice(0, slashIndex);
        const key = path.slice(slashIndex + 1);
        if (bucket.length === 0 || key.length === 0) {
            throw new Error(`Invalid path: ${path}. Expected <bucket-name>/<path>`);
        }

        return {
            bucket,
            key,
        };
    }

    //
    // Returns true if the specified directory is empty.
    //
    async isEmpty(path: string): Promise<boolean> {
        const files = await this.listFiles(path, 1);
        if (files.names.length > 0) {
            return false;
        }

        const dirs = await this.listDirs(path, 1);
        if (dirs.names.length > 0) {
            return false;
        }

        return true;
    }

    //
    // List files in storage.
    //
    async listFiles(path: string, max: number, next?: string): Promise<IListResult> {

        let { bucket, key } = parseS3ListPath(path);

        if (key === "") {
            // Empty path is ok.
        }
        else if (key === "/") {
            key = ""; // The root directory is empty.
        }
        else {
            if (key.startsWith("/")) {
                key = key.slice(1); // Remove leading slash.
            }

            if (!key.endsWith("/")) {
                key = `${key}/`; // Ensure the path ends with a slash.
            }
        }

        try {
            const response = await this.s3.send(new ListObjectsV2Command({
                Bucket: bucket,
                Prefix: key,
                Delimiter: "/",
                MaxKeys: max,
                ContinuationToken: next,
            }));

            let names = response.Contents?.map(item => {
                    const nameParts = item.Key!.split("/");
                    return nameParts[nameParts.length - 1]; // The last part is the file name or asset ID.
                });
    
            if (names === undefined) {
                names = [];
            }
            else {
                names = names.filter(name => name !== ""); // Remove empty names.
            }
    
            return {
                names,
                next: response.NextContinuationToken,
            };
        }
        catch (err: any) {
            throw new WrappedError(`Failed to list files in ${path}: ${err.message}`, { cause: err });
        }
    }

    //
    // List directories in storage.
    //
    async listDirs(path: string, max: number, next?: string): Promise<IListResult> {

        let { bucket, key } = parseS3ListPath(path);

        if (key === "") {
            // Empty path is ok.
        }
        else if (key === "/") {
            key = ""; // The root directory is empty.
        }
        else {
            if (!key.endsWith("/")) {
                key = `${key}/`; // Ensure the path ends with a slash.
            }

            if (key.startsWith("/")) {
                key = key.slice(1); // Remove leading slash.
            }
        }

        try {
            const response = await this.s3.send(new ListObjectsV2Command({
                Bucket: bucket,
                Prefix: key,
                Delimiter: "/",
                MaxKeys: max,
                ContinuationToken: next,
            }));

            let names = response.CommonPrefixes?.map(item => {
                const nameParts = item.Prefix!
                    .slice(0, item.Prefix!.length-1) // Trims trailing slash.
                    .split("/");
                return nameParts[nameParts.length - 1]; // The last part is the file name or asset ID.
            });

            if (names === undefined) {
                names = [];
            }
            else {
                names = names.filter(name => name !== ""); // Remove empty names.
            }

            return {
                names,
                next: response.NextContinuationToken,
            };
        }
        catch (err: any) {
            throw new WrappedError(`Failed to list directories in ${path}: ${err.message}`, { cause: err });
        }
    }

    //
    // Returns true if the specified file exists.
    //
    async fileExists(filePath: string): Promise<boolean> {
        let { bucket, key } = this.parsePath(filePath);
        if (key.startsWith("/")) {
            key = key.slice(1); // Remove leading slash.
        }

        try {
            await this.s3.send(new HeadObjectCommand({
                Bucket: bucket,
                Key: key,
            }));
            return true;
        }
        catch (err: any) {
            if (err.name === "NotFound" || err.$metadata?.httpStatusCode === 404) {
                return false;
            }
            throw new WrappedError(`Failed to check if file exists: ${err.message}`, { cause: err });
        }
    }

    //
    // Returns true if the specified directory exists (has at least one object with the prefix).
    //
    async dirExists(dirPath: string): Promise<boolean> {
        let { bucket, key } = this.parsePath(dirPath);

        if (key === "") {
            // Empty path is ok, bucket always exists if we've gotten this far
            return true;
        }
        else if (key === "/") {
            key = ""; // The root directory is empty.
        }
        else {
            if (key.startsWith("/")) {
                key = key.slice(1); // Remove leading slash.
            }

            if (!key.endsWith("/")) {
                key = `${key}/`; // Ensure the path ends with a slash for directory check
            }
        }

        try {
            const response = await this.s3.send(new ListObjectsV2Command({
                Bucket: bucket,
                Prefix: key,
                MaxKeys: 1, // We only need to find one object to confirm directory exists
            }));
            return (response.Contents !== undefined && response.Contents.length > 0);
        }
        catch (err: any) {
            throw new WrappedError(`Failed to check if directory exists: ${err.message}`, { cause: err });
        }
    }
    
    //
    // Gets info about an asset.
    //
    async info(filePath: string): Promise<IFileInfo | undefined> {
        let { bucket, key } = this.parsePath(filePath);
        if (key.startsWith("/")) {
            key = key.slice(1); // Remove leading slash.
        }

        try {
            const headResult = await this.s3.send(new HeadObjectCommand({
                Bucket: bucket,
                Key: key,
            }));
            if (!headResult.LastModified) {
                throw new Error(`LastModified is undefined for ${filePath}`);
            }
            return {
                contentType: headResult.ContentType as string,
                length: headResult.ContentLength as number,
                lastModified: headResult.LastModified!,
            };
        }
        catch (err: any) {
            if (err.name === "NotFound" || err.$metadata?.httpStatusCode === 404) {
                return undefined;
            }
            throw new WrappedError(`Failed to get info for ${filePath}: ${err.message}`, { cause: err });
        }
    }

    //
    // The SHA-256 S3 kept of the object when it was written, read with a HEAD request.
    //
    // Undefined when the object was written without one (by an older version of this code, or by
    // anything else), when it is not there, or when the checksum is a composite of a multipart
    // upload's parts, which is a hash of hashes rather than a hash of the file and so cannot be
    // compared against one. The caller falls back to reading the file and hashing it.
    //
    async storedHash(filePath: string): Promise<Buffer | undefined> {
        let { bucket, key } = this.parsePath(filePath);
        if (key.startsWith("/")) {
            key = key.slice(1); // Remove leading slash.
        }

        try {
            const headResult = await this.s3.send(new HeadObjectCommand({
                Bucket: bucket,
                Key: key,
                ChecksumMode: "ENABLED",
            }));

            const checksum = headResult.ChecksumSHA256;
            if (!checksum || checksum.includes("-")) {
                return undefined;
            }

            return Buffer.from(checksum, "base64");
        }
        catch (err: any) {
            if (err.name === "NotFound" || err.$metadata?.httpStatusCode === 404) {
                return undefined;
            }
            throw new WrappedError(`Failed to get the stored hash of ${filePath}: ${err.message}`, { cause: err });
        }
    }

    //
    // Reads a file from storage.
    // Returns undefined if the file doesn't exist.
    //
    async read(filePath: string): Promise<Buffer | undefined> {
        let { bucket, key } = this.parsePath(filePath);
        if (key.startsWith("/")) {
            key = key.slice(1); // Remove leading slash.
        }

        try {
            const response = await this.s3.send(new GetObjectCommand({
                Bucket: bucket,
                Key: key,
            }));
            const bodyBytes = await response.Body!.transformToByteArray();
            return Buffer.from(bodyBytes);
        }
        catch (err: any) {
            if (err.name === "NoSuchKey") {
                return undefined;
            }
            throw new WrappedError(`Failed to read ${filePath}: ${err.message}`, { cause: err });            
        }
    }

    //
    // Writes a file to storage.
    //
    async write(filePath: string, contentType: string | undefined, data: Buffer): Promise<void> {

        let { bucket, key } = this.parsePath(filePath);
        if (key.startsWith("/")) {
            key = key.slice(1); // Remove leading slash.
        }

        //
        // NOTE: These values have been tuned to allow uploading of 2GB+ files.
        //
        try {
            await new Upload({
                client: this.s3,
                params: {
                    Bucket: bucket,
                    Key: key,
                    Body: data,
                    ContentType: contentType,
                    ContentLength: data.length,
                },
                partSize: UPLOAD_PART_BYTES,
                queueSize: 1,
            }).done();
        }
        catch (err: any) {
            throw new WrappedError(`Failed to write to ${filePath}: ${err.message}`, { cause: err });
        }
    }

    //
    // Streams a file from storage.
    //
    async readStream(filePath: string): Promise<Readable> {
        let { bucket, key } = this.parsePath(filePath);
        if (key.startsWith("/")) {
            key = key.slice(1); // Remove leading slash.
        }

        return new S3RangeReadableStream(this.s3, bucket, key);
    }

    //
    // Writes an input stream to storage.
    //
    async writeStream(filePath: string, contentType: string | undefined, inputStream: Readable, contentLength?: number): Promise<void> {

        let { bucket, key } = this.parsePath(filePath);
        if (key.startsWith("/")) {
            key = key.slice(1); // Remove leading slash.
        }

        //
        // NOTE: These values have been tuned to allow uploading of 2GB+ files.
        //
        try {
            await new Upload({
                client: this.s3,
                params: {
                    Bucket: bucket,
                    Key: key,
                    Body: inputStream,
                    ContentType: contentType,
                    ContentLength: contentLength,
                },
                partSize: UPLOAD_PART_BYTES,
                queueSize: 1,
            }).done();
        }
        catch (err: any) {
            throw new WrappedError(`Failed to write stream to ${filePath}: ${err.message}`, { cause: err });
        }
    }

    //
    // Writes a stream whose SHA-256 the caller already knows, handing the hash to S3 with it.
    //
    // S3 checks the body against the hash and refuses the write if they differ, so the upload
    // verifies itself, and it keeps the hash for storedHash to answer with afterwards. Nothing here
    // or in the SDK computes it: given the value, the SDK sends it rather than hashing the body,
    // which is the whole point. Hashing in the embedded engine is pure JavaScript at well under a
    // megabyte a second, and it held a 100MB video for over a quarter of an hour on a Pixel 6
    // without a byte reaching the server.
    //
    // The hash is sent only for a body that fits in one part. A multipart upload's checksum is a hash
    // of its parts' hashes rather than a hash of the object, so the two cannot be compared, and a
    // file bigger than the part size below is written exactly as writeStream writes it.
    //
    // The upload goes through the same uploader as the other writes rather than a bare PutObject. It
    // is what knows how to send a stream: handing the stream straight to PutObject uploaded nothing
    // at all, and the sync found the file missing at the far end and reported it as a failed copy.
    //
    async writeStreamHashed(filePath: string, contentType: string | undefined, inputStream: Readable, contentLength: number, sha256: Buffer): Promise<boolean> {

        let { bucket, key } = this.parsePath(filePath);
        if (key.startsWith("/")) {
            key = key.slice(1); // Remove leading slash.
        }

        const fitsInOnePart = contentLength <= SINGLE_PART_MAX_BYTES;

        if (fitsInOnePart) {
            // One request, with the stream handed to the SDK as it is.
            //
            // The multipart uploader would read the stream into a buffer first, and on a phone that
            // is the expensive half of the work: the mobile shims recognise a file-backed stream
            // piped into a request and have the file sent from disk to the socket natively, which
            // only happens if the stream reaches the request unread.
            try {
                await this.s3.send(new PutObjectCommand({
                    Bucket: bucket,
                    Key: key,
                    Body: inputStream,
                    ContentType: contentType,
                    ContentLength: contentLength,
                    ChecksumSHA256: sha256.toString("base64"),
                }));

                // The server checked the body against the hash and would have refused it otherwise,
                // so the caller needs no HEAD afterwards to know the copy is right.
                return true;
            }
            catch (err: any) {
                throw new WrappedError(`Failed to write stream to ${filePath}: ${err.message}`, { cause: err });
            }
        }

        try {
            await new Upload({
                client: this.s3,
                params: {
                    Bucket: bucket,
                    Key: key,
                    Body: inputStream,
                    ContentType: contentType,
                    ContentLength: contentLength,
                },
                // Only a body too large to send whole reaches here, so it goes up in parts, which
                // cannot carry a whole-object checksum: a multipart checksum is a hash of the parts'
                // hashes rather than of the object.
                partSize: UPLOAD_PART_BYTES,
                queueSize: 1,
            }).done();

            // Each part carried its own checksum, but the object as a whole did not, so nothing here
            // has compared what landed against the hash the caller holds.
            return false;
        }
        catch (err: any) {
            throw new WrappedError(`Failed to write stream to ${filePath}: ${err.message}`, { cause: err });
        }
    }

    //
    // Deletes a file from storage.
    //
    async deleteFile(filePath: string): Promise<void> {

        let { bucket, key } = this.parsePath(filePath);
        if (key.startsWith("/")) {
            key = key.slice(1); // Remove leading slash.
        }

        try {
            await this.s3.send(new DeleteObjectCommand({
                Bucket: bucket,
                Key: key,
            }));
        }
        catch (err: any) {
            // Ignore errors if the file doesn't exist
        }
    }
    
    //
    // Deletes a directory and all its contents from storage.
    //
    async deleteDir(dirPath: string): Promise<void> {

        let { bucket, key } = this.parsePath(dirPath);
        if (key.startsWith("/")) {
            key = key.slice(1); // Remove leading slash.
        }
        
        // Make sure the key ends with a slash to indicate a directory
        if (!key.endsWith("/")) {
            key = key + "/";
        }
        
        try {
            let isTruncated = true;
            let continuationToken: string | undefined = undefined;
            
            while (isTruncated) {
                const listResult: ListObjectsV2CommandOutput = await this.s3.send(new ListObjectsV2Command({
                    Bucket: bucket,
                    Prefix: key,
                    ContinuationToken: continuationToken,
                }));

                if (listResult.Contents && listResult.Contents.length > 0) {
                    // Batch delete objects (up to 1000 at a time)
                    await this.s3.send(new DeleteObjectsCommand({
                        Bucket: bucket,
                        Delete: {
                            Objects: listResult.Contents.map(obj => ({ Key: obj.Key! }))
                        },
                    }));
                }
                
                isTruncated = !!listResult.IsTruncated;
                continuationToken = listResult.NextContinuationToken;
            }
        }
        catch (err: any) {
            // Ignore errors if the directory doesn't exist
        }
    }
 
    //
    // Copies a file from one location to another.
    // srcPath can include the src bucket name.
    //
    async copyTo(srcPath: string, destPath: string): Promise<void> {

        let { bucket: srcBucket, key: srcKey } = this.parsePath(srcPath);
        if (srcKey.startsWith("/")) {
            srcKey = srcKey.slice(1); // Remove leading slash.
        }

        let { bucket: destBucket, key: destKey } = this.parsePath(destPath);
        if (destKey.startsWith("/")) {
            destKey = destKey.slice(1); // Remove leading slash.
        }

        try {
            await this.s3.send(new CopyObjectCommand({
                Bucket: destBucket,
                CopySource: `${srcBucket}/${srcKey}`,
                Key: destKey,
            }));
        }
        catch (err: any) {
            throw new WrappedError(`Failed to copy from ${srcPath} to ${destPath}: ${err.message}`, { cause: err });
        }
    }

    //
    // Checks if a write lock is acquired for the specified file.
    // Returns the lock information if it exists, undefined otherwise.
    //
    async checkWriteLock(filePath: string): Promise<IWriteLockInfo | undefined> {
       
        let { bucket, key } = this.parsePath(filePath);
        if (key.startsWith("/")) {
            key = key.slice(1); // Remove leading slash.
        }

        try {
            const response = await this.s3.send(new GetObjectCommand({
                Bucket: bucket,
                Key: key,
            }));
            const lockContent = await response.Body!.transformToString("utf8");
            if (lockContent) {
                const lockData = JSON.parse(lockContent.trim());
                return {
                    owner: lockData.owner,
                    acquiredAt: new Date(lockData.acquiredAt),
                    timestamp: lockData.timestamp
                };
            }
            return undefined;
        }
        catch (err: any) {
            if (err.name === "NoSuchKey") {
                return undefined;
            }
            throw new WrappedError(`Failed to check write lock for ${filePath}: ${err.message}`, { cause: err });
        }
    }

    //
    // Attempts to acquire a write lock for the specified file.
    // Returns true if the lock was acquired, false if it already exists.
    //
    async acquireWriteLock(filePath: string, owner: string): Promise<boolean> {
        
        const timestamp = Date.now();
        const processId = process.pid;
        
        if (log.verboseEnabled) {
            log.verbose(`[LOCK] ${timestamp},ACQUIRE_ATTEMPT,${processId},${owner},${filePath}`);
        }
        
        let { bucket, key } = this.parsePath(filePath);
        if (key.startsWith("/")) {
            key = key.slice(1); // Remove leading slash.
        }

        // Create lock information with owner and timestamp
        const lockInfo = {
            owner,
            acquiredAt: new Date().toISOString(),
            timestamp
        };
        const lockContent = JSON.stringify(lockInfo);
        const lockBody = Buffer.from(lockContent, "utf8");

        const putParams = {
            Bucket: bucket,
            Key: key,
            Body: lockBody,
            ContentType: "application/json",
            ContentLength: lockBody.byteLength,
            IfNoneMatch: "*",
        };

        try {
            // Use conditional write to ensure atomic "create if not exists"
            await this.s3.send(new PutObjectCommand(putParams));

            if (log.verboseEnabled) {
                log.verbose(`[LOCK] ${timestamp},ACQUIRE_SUCCESS,${processId},${owner},${filePath}`);
            }
            return true;
        }
        catch (putErr: any) {
            // If the condition failed (object already exists), check if it's timed out
            if (putErr.$metadata?.httpStatusCode === 412 || putErr.name === "PreconditionFailed" || putErr.name === "ConditionalRequestConflict") {
                // Check if existing lock has timed out (10 seconds = 10000ms)
                const existingLock = await this.checkWriteLock(filePath);
                if (existingLock) {
                    const lockAge = timestamp - existingLock.timestamp;
                    if (lockAge > WRITE_LOCK_TIMEOUT_MS) {
                        // Lock has timed out, delete it and try to acquire new lock
                        if (log.verboseEnabled) {
                            log.verbose(`[LOCK] ${timestamp},ACQUIRE_TIMEOUT_BREAK,${processId},${owner},${filePath},age:${lockAge}ms,oldOwner:${existingLock.owner}`);
                        }
                        
                        try {
                            // Delete the expired lock
                            await this.s3.send(new DeleteObjectCommand({
                                Bucket: bucket,
                                Key: key,
                            }));

                            // Try to acquire the lock again (without conditional header this time)
                            const retryPutParams = { ...putParams, IfNoneMatch: undefined };
                            await this.s3.send(new PutObjectCommand(retryPutParams));

                            if (log.verboseEnabled) {
                                log.verbose(`[LOCK] ${timestamp},ACQUIRE_SUCCESS_AFTER_TIMEOUT,${processId},${owner},${filePath}`);
                            }
                            return true;
                        }
                        catch (retryErr) {
                            // Another process might have acquired the lock in the meantime
                            if (log.verboseEnabled) {
                                log.verbose(`[LOCK] ${timestamp},ACQUIRE_FAILED_RETRY,${processId},${owner},${filePath}`);
                            }
                            return false;
                        }
                    }
                    else {
                        // Lock is still valid
                        if (log.verboseEnabled) {
                            log.verbose(`[LOCK] ${timestamp},ACQUIRE_FAILED_EXISTS,${processId},${owner},${filePath},age:${lockAge}ms,owner:${existingLock.owner}`);
                        }
                        return false;
                    }
                }
                else {
                    // The write above was refused because the lock is there, but reading it back
                    // returned nothing. This used to assume the lock was corrupt, delete it and take
                    // it. It is not corrupt: the read simply raced its owner, who is still in the
                    // critical section. Deleting it here let three processes write one database at
                    // once and one of them lost its records (S3-LOCK-BROKEN-WHILE-HELD in
                    // docs/flaky-tests-registry.md). Refuse instead and let the caller retry.
                    if (log.verboseEnabled) {
                        log.verbose(`[LOCK] ${timestamp},ACQUIRE_FAILED_UNREADABLE,${processId},${owner},${filePath}`);
                    }
                    return false;
                }
            }
            
            if (log.verboseEnabled) {
                log.verbose(`[LOCK] ${timestamp},ACQUIRE_FAILED_ERROR,${processId},${owner},${filePath},error:${putErr.message}`);
            }
            
            throw new WrappedError(`Failed to acquire write lock for ${filePath}: ${putErr.message}`, { cause: putErr });
        }
    }

    //
    // Releases a write lock for the specified file.
    //
    async releaseWriteLock(filePath: string): Promise<void> {
        
        let { bucket, key } = this.parsePath(filePath);
        if (key.startsWith("/")) {
            key = key.slice(1); // Remove leading slash.
        }

        try {
            await this.s3.send(new DeleteObjectCommand({
                Bucket: bucket,
                Key: key,
            }));
            if (log.verboseEnabled) {
                log.verbose(`[LOCK] ${Date.now()},RELEASE_SUCCESS,${process.pid},unknown,${filePath}`);
            }
        }
        catch (err: any) {
            // Ignore errors if the lock file doesn't exist
            if (log.verboseEnabled) {
                log.verbose(`[LOCK] ${Date.now()},RELEASE_FAILED,${process.pid},unknown,${filePath},error:${err?.message || "unknown"}`);
            }
        }
    }

    //
    // Refreshes a write lock for the specified file, updating its timestamp.
    // Throws an error if the lock is no longer owned by the specified owner.
    //
    async refreshWriteLock(filePath: string, owner: string): Promise<void> {
        
        const timestamp = Date.now();
        const processId = process.pid;
        
        if (log.verboseEnabled) {
            log.verbose(`[LOCK] ${timestamp},REFRESH_ATTEMPT,${processId},${owner},${filePath}`);
        }
        
        let { bucket, key } = this.parsePath(filePath);
        if (key.startsWith("/")) {
            key = key.slice(1); // Remove leading slash.
        }

        try {
            // Check if lock exists and we own it
            const existingLock = await this.checkWriteLock(filePath);
            if (!existingLock) {
                throw new Error(`Cannot refresh write lock: lock does not exist for ${filePath}`);
            }
            
            if (existingLock.owner !== owner) {
                throw new Error(`Cannot refresh write lock: lock is owned by ${existingLock.owner}, not ${owner} for ${filePath}`);
            }
                       
            // Update the lock with new timestamp
            const lockInfo = {
                owner,
                acquiredAt: new Date().toISOString(),
                timestamp
            };
            const lockContent = JSON.stringify(lockInfo);
            const lockBody = Buffer.from(lockContent, "utf8");

            await this.s3.send(new PutObjectCommand({
                Bucket: bucket,
                Key: key,
                Body: lockBody,
                ContentType: "application/json",
                ContentLength: lockBody.byteLength,
            }));

            if (log.verboseEnabled) {
                log.verbose(`[LOCK] ${timestamp},REFRESH_SUCCESS,${processId},${owner},${filePath}`);
            }
        }
        catch (err: any) {
            if (log.verboseEnabled) {
                log.verbose(`[LOCK] ${timestamp},REFRESH_FAILED,${processId},${owner},${filePath},error:${err.message}`);
            }
            throw err;
        }
    }
}
