import { Readable } from "stream";
import aws from "aws-sdk";
import { IFileInfo, IListResult, IStorage, IWriteLockInfo, checkReadonly } from "./storage";
import { WrappedError } from "utils";
import { log } from "utils";

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
    // AWS S3 interface.
    //
    private s3!: aws.S3;

    constructor(public readonly location: string, private verbose?: boolean, credentials?: IS3Credentials, public readonly isReadonly: boolean = false) {
        const s3Config: aws.S3.ClientConfiguration = {
            endpoint: credentials?.endpoint || process.env.AWS_ENDPOINT,
        };

        if (credentials) {
            s3Config.accessKeyId = credentials.accessKeyId;
            s3Config.secretAccessKey = credentials.secretAccessKey;
            if (credentials.region) {
                s3Config.region = credentials.region;
            }
        }

        this.s3 = new aws.S3(s3Config);
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

        const listParams: aws.S3.Types.ListObjectsV2Request = {
            Bucket: bucket,
            Prefix: key,
            Delimiter: "/",
            MaxKeys: max,
            ContinuationToken: next,
        };

        try {
            const response = await this.s3.listObjectsV2(listParams).promise();
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
            if (this.verbose) {
                throw new WrappedError(`Failed to list files in ${path}: ${err.message}`, { cause: err });
            }
            throw err;
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

        const listParams: aws.S3.Types.ListObjectsV2Request = {
            Bucket: bucket,
            Prefix: key,
            Delimiter: "/",
            MaxKeys: max,
            ContinuationToken: next,
        };

        try {
            const response = await this.s3.listObjectsV2(listParams).promise();
    
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
            if (this.verbose) {
                throw new WrappedError(`Failed to list directories in ${path}: ${err.message}`, { cause: err });
            }
            throw err;
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

        const headParams: aws.S3.Types.HeadObjectRequest = {
            Bucket: bucket,
            Key: key,
        };
        try {
            await this.s3.headObject(headParams).promise();
            return true;
        }
        catch (err: any) {
            if (err.code === 'NotFound') {
                return false;
            }
            else if (this.verbose) {
                throw new WrappedError(`Failed to check if file exists: ${err.message}`, { cause: err });
            }
            throw err;
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

        const listParams: aws.S3.Types.ListObjectsV2Request = {
            Bucket: bucket,
            Prefix: key,
            MaxKeys: 1, // We only need to find one object to confirm directory exists
        };

        try {
            const response = await this.s3.listObjectsV2(listParams).promise();
            return (response.Contents !== undefined && response.Contents.length > 0);
        }
        catch (err: any) {
            if (this.verbose) {
                throw new WrappedError(`Failed to check if directory exists: ${err.message}`, { cause: err });
            }
            throw err;
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

        const headParams: aws.S3.Types.HeadObjectRequest = {
            Bucket: bucket,
            Key: key,
        };
        try {
            const headResult = await this.s3.headObject(headParams).promise();
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
            if (err.statusCode === 404) {
                return undefined;
            }
            else if (this.verbose) {
                throw new WrappedError(`Failed to get info for ${filePath}: ${err.message}`, { cause: err });
            }
            throw err;
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

        const getParams: aws.S3.Types.GetObjectRequest = {
            Bucket:bucket, 
            Key: key,
        };
        try {
            const getObjectOutput = await this.s3.getObject(getParams).promise();
            return getObjectOutput.Body as Buffer;
        }
        catch (err: any) {
            if (err.code === 'NoSuchKey') {
                return undefined;
            }
            else if (this.verbose) {
                throw new WrappedError(`Failed to read ${filePath}: ${err.message}`, { cause: err });
            }
            throw err;            
        }
    }

    //
    // Writes a file to storage.
    //
    async write(filePath: string, contentType: string | undefined, data: Buffer): Promise<void> {
        checkReadonly(this.isReadonly, 'write file');

        let { bucket, key } = this.parsePath(filePath);
        if (key.startsWith("/")) {
            key = key.slice(1); // Remove leading slash.
        }

        const params: aws.S3.Types.PutObjectRequest = {
            Bucket: bucket,
            Key: key,
            Body: data,
            ContentType: contentType,
            ContentLength: data.length,
        };    
        
        //
        // NOTE: These values have been tuned to allow uploading of 2GB+ files.
        //    
        const options: aws.S3.ManagedUpload.ManagedUploadOptions = {
            partSize: 100 * 1024 * 1024, // 100 MB
            queueSize: 1,
        };

        try {
            const upload = this.s3.upload(params, options);
    
            // upload.on('httpUploadProgress', (progress) => {
            //     console.log(`Uploaded ${progress.loaded/1024/1024} of ${progress.total/1024/1024} MB.`);
    
            //     if (progress.total) {
            //         const percentage = ((progress.loaded / progress.total) * 100).toFixed(2);
            //         console.log(`S3 Upload Progress: ${percentage}%`);
            //     }
            // });
    
            await upload.promise();
        }
        catch (err: any) {
            if (this.verbose) {
                throw new WrappedError(`Failed to write to ${filePath}: ${err.message}`, { cause: err });
            }
            throw err;
        }       
    }

    //
    // Streams a file from stroage.
    //
    readStream(filePath: string): Readable {
        let { bucket, key } = this.parsePath(filePath);
        if (key.startsWith("/")) {
            key = key.slice(1); // Remove leading slash.
        }

        const getParams: aws.S3.Types.GetObjectRequest = {
            Bucket: bucket, 
            Key: key,
        };

        try {
            return this.s3.getObject(getParams).createReadStream();
        }
        catch (err: any) {
            if (this.verbose) {
                throw new WrappedError(`Failed to read stream from ${filePath}: ${err.message}`, { cause: err });
            }
            throw err;
        }
    }

    //
    // Writes an input stream to storage.
    //
    async writeStream(filePath: string, contentType: string | undefined, inputStream: Readable, contentLength?: number): Promise<void> {
        checkReadonly(this.isReadonly, 'write stream');

        let { bucket, key } = this.parsePath(filePath);
        if (key.startsWith("/")) {
            key = key.slice(1); // Remove leading slash.
        }

        const params: aws.S3.Types.PutObjectRequest = {
            Bucket: bucket,
            Key: key,
            Body: inputStream,
            ContentType: contentType,
            ContentLength: contentLength,
        };    

        //
        // NOTE: These values have been tuned to allow uploading of 2GB+ files.
        //    
        const options: aws.S3.ManagedUpload.ManagedUploadOptions = {
            partSize: 100 * 1024 * 1024, // 100 MB
            queueSize: 1,
        };

        try {
            const upload = this.s3.upload(params, options);
    
            // upload.on('httpUploadProgress', (progress) => {
            //     console.log(`Uploaded ${progress.loaded/1024/1024} of ${progress.total/1024/1024} MB.`);
    
            //     if (progress.total) {
            //         const percentage = ((progress.loaded / progress.total) * 100).toFixed(2);
            //         console.log(`S3 Upload Progress: ${percentage}%`);
            //     }
            // });
    
            await upload.promise();
        }
        catch (err: any) {
            if (this.verbose) {
                throw new WrappedError(`Failed to write stream to ${filePath}: ${err.message}`, { cause: err });
            }
            throw err;
        }
    }

    //
    // Deletes a file from storage.
    //
    async deleteFile(filePath: string): Promise<void> {
        checkReadonly(this.isReadonly, 'delete file');
        let { bucket, key } = this.parsePath(filePath);
        if (key.startsWith("/")) {
            key = key.slice(1); // Remove leading slash.
        }

        const deleteParams: aws.S3.Types.DeleteObjectRequest = {
            Bucket: bucket,
            Key: key,
        };

        try {
            await this.s3.deleteObject(deleteParams).promise();
        }
        catch (err: any) {
            // Ignore errors if the file doesn't exist
        }
    }
    
    //
    // Deletes a directory and all its contents from storage.
    //
    async deleteDir(dirPath: string): Promise<void> {
        checkReadonly(this.isReadonly, 'delete directory');
        let { bucket, key } = this.parsePath(dirPath);
        if (key.startsWith("/")) {
            key = key.slice(1); // Remove leading slash.
        }
        
        // Make sure the key ends with a slash to indicate a directory
        if (!key.endsWith("/")) {
            key = key + "/";
        }
        
        try {
            // List all objects with the directory prefix
            const listParams: aws.S3.Types.ListObjectsV2Request = {
                Bucket: bucket,
                Prefix: key
            };
            
            let isTruncated = true;
            let continuationToken: string | undefined = undefined;
            
            while (isTruncated) {
                if (continuationToken) {
                    listParams.ContinuationToken = continuationToken;
                }
                
                const listResult = await this.s3.listObjectsV2(listParams).promise();
                
                if (listResult.Contents && listResult.Contents.length > 0) {
                    // Batch delete objects (up to 1000 at a time)
                    const deleteParams: aws.S3.Types.DeleteObjectsRequest = {
                        Bucket: bucket,
                        Delete: {
                            Objects: listResult.Contents.map(obj => ({ Key: obj.Key! }))
                        }
                    };
                    
                    await this.s3.deleteObjects(deleteParams).promise();
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

        const copyParams: aws.S3.Types.CopyObjectRequest = {
            Bucket: destBucket,
            CopySource: `${srcBucket}/${srcKey}`,
            Key: destKey,
        };

        try {
            await this.s3.copyObject(copyParams).promise();
        }
        catch (err: any) {
            if (this.verbose) {
                throw new WrappedError(`Failed to copy from ${srcPath} to ${destPath}: ${err.message}`, { cause: err });
            }
            throw err;
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

        const getParams: aws.S3.Types.GetObjectRequest = {
            Bucket: bucket,
            Key: key,
        };

        try {
            const getObjectOutput = await this.s3.getObject(getParams).promise();
            const lockContent = getObjectOutput.Body?.toString('utf8');
            if (lockContent) {
                const lockData = JSON.parse(lockContent.trim());
                return {
                    owner: lockData.owner,
                    acquiredAt: new Date(lockData.acquiredAt),
                    timestamp: lockData.timestamp
                };
            }
            return undefined;
        } catch (err: any) {
            if (err.code === 'NoSuchKey') {
                return undefined;
            }
            if (this.verbose) {
                throw new WrappedError(`Failed to check write lock for ${filePath}: ${err.message}`, { cause: err });
            }
            throw err;
        }
    }

    //
    // Attempts to acquire a write lock for the specified file.
    // Returns true if the lock was acquired, false if it already exists.
    //
    async acquireWriteLock(filePath: string, owner: string): Promise<boolean> {
        checkReadonly(this.isReadonly, 'acquire write lock');
        
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

        const putParams: aws.S3.Types.PutObjectRequest = {
            Bucket: bucket,
            Key: key,
            Body: Buffer.from(lockContent, 'utf8'),
            ContentType: 'application/json',
            ContentLength: Buffer.byteLength(lockContent, 'utf8'),
        };

        try {
            // Use conditional write to ensure atomic "create if not exists"
            const request = this.s3.putObject(putParams);
            request.httpRequest.headers['If-None-Match'] = '*';
            await request.promise();
            
            if (log.verboseEnabled) {
                log.verbose(`[LOCK] ${timestamp},ACQUIRE_SUCCESS,${processId},${owner},${filePath}`);
            }
            return true;
        } catch (putErr: any) {
            // If the condition failed (object already exists), return false
            if (putErr.statusCode === 412 || putErr.code === 'PreconditionFailed') {
                if (log.verboseEnabled) {
                    log.verbose(`[LOCK] ${timestamp},ACQUIRE_FAILED_EXISTS,${processId},${owner},${filePath}`);
                }
                return false;
            }
            
            if (log.verboseEnabled) {
                log.verbose(`[LOCK] ${timestamp},ACQUIRE_FAILED_ERROR,${processId},${owner},${filePath},error:${putErr.message}`);
            }
            
            if (this.verbose) {
                throw new WrappedError(`Failed to acquire write lock for ${filePath}: ${putErr.message}`, { cause: putErr });
            }
            throw putErr;
        }
    }

    //
    // Releases a write lock for the specified file.
    //
    async releaseWriteLock(filePath: string): Promise<void> {
        checkReadonly(this.isReadonly, 'release write lock');
        
        let { bucket, key } = this.parsePath(filePath);
        if (key.startsWith("/")) {
            key = key.slice(1); // Remove leading slash.
        }

        const deleteParams: aws.S3.Types.DeleteObjectRequest = {
            Bucket: bucket,
            Key: key,
        };

        try {
            await this.s3.deleteObject(deleteParams).promise();
            if (log.verboseEnabled) {
                log.verbose(`[LOCK] ${Date.now()},RELEASE_SUCCESS,${process.pid},unknown,${filePath}`);
            }
        } catch (err: any) {
            // Ignore errors if the lock file doesn't exist
            if (log.verboseEnabled) {
                log.verbose(`[LOCK] ${Date.now()},RELEASE_FAILED,${process.pid},unknown,${filePath},error:${err?.message || 'unknown'}`);
            }
        }
    }
}