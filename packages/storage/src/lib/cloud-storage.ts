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
import { Upload } from "@aws-sdk/lib-storage";
import { IFileInfo, IListResult, IStorage, IWriteLockInfo } from "./storage";
import { WrappedError } from "utils";
import { log } from "utils";

// Write lock timeout in milliseconds (10 seconds)
const WRITE_LOCK_TIMEOUT_MS = 10000;

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

        this.s3 = new S3Client({
            ...(endpoint && { endpoint }),
            requestHandler: {
                requestTimeout: 30000,
                connectionTimeout: 10000,
            },
            ...(credentials && {
                credentials: {
                    accessKeyId: credentials.accessKeyId,
                    secretAccessKey: credentials.secretAccessKey,
                },
                ...(credentials.region && { region: credentials.region }),
            }),
        });
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

        let { bucket, key } = this.parsePath(path);

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

        let { bucket, key } = this.parsePath(path);

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
                partSize: 100 * 1024 * 1024, // 100 MB
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

        try {
            const response = await this.s3.send(new GetObjectCommand({
                Bucket: bucket,
                Key: key,
            }));
            return response.Body as Readable;
        }
        catch (err: any) {
            throw new WrappedError(`Failed to read stream from ${filePath}: ${err.message}`, { cause: err });
        }
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
                partSize: 100 * 1024 * 1024, // 100 MB
                queueSize: 1,
            }).done();
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
                    // Lock file exists but is corrupted, try to delete and retry
                    if (log.verboseEnabled) {
                        log.verbose(`[LOCK] ${timestamp},ACQUIRE_CORRUPTED_BREAK,${processId},${owner},${filePath}`);
                    }
                    
                    try {
                        await this.s3.send(new DeleteObjectCommand({
                            Bucket: bucket,
                            Key: key,
                        }));

                        const retryPutParams = { ...putParams, IfNoneMatch: undefined };
                        await this.s3.send(new PutObjectCommand(retryPutParams));

                        if (log.verboseEnabled) {
                            log.verbose(`[LOCK] ${timestamp},ACQUIRE_SUCCESS_AFTER_CORRUPT,${processId},${owner},${filePath}`);
                        }
                        return true;
                    }
                    catch (retryErr) {
                        if (log.verboseEnabled) {
                            log.verbose(`[LOCK] ${timestamp},ACQUIRE_FAILED_RETRY,${processId},${owner},${filePath}`);
                        }
                        return false;
                    }
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
