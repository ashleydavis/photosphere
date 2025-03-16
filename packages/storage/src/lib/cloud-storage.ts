import { Readable } from "stream";
import aws from "aws-sdk";
import { IFileInfo, IListResult, IStorage } from "./storage";
import { WrappedError } from "utils";

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

    constructor(private verbose?: boolean) {
        
        this.s3 = new aws.S3({
            endpoint: process.env.AWS_ENDPOINT,
        });
    }

    //
    // Parse the path and extract the bucket and key.
    //
    private parsePath(path: string): { bucket: string, key: string } {
        const parts = path.split(":");
        if (parts.length !== 2) {
            throw new Error(`Invalid path: ${path}`);
        }
        return {
            bucket: parts[0],
            key: parts[1],
        };
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
    
            const names = response.CommonPrefixes?.map(item => {
                const nameParts = item.Prefix!
                    .slice(0, item.Prefix!.length-1) // Trims trailing slash.
                    .split("/");
                return nameParts[nameParts.length - 1]; // The last part is the file name or asset ID.
            }) || [];
    
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
            return {
                contentType: headResult.ContentType as string,
                length: headResult.ContentLength as number,
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
        
        const options: aws.S3.ManagedUpload.ManagedUploadOptions = {
            partSize: 5 * 1024 * 1024, // 5 MB
            queueSize: 5,
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

        const options: aws.S3.ManagedUpload.ManagedUploadOptions = {
            partSize: 5 * 1024 * 1024, // 5 MB
            queueSize: 5,
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
    // Deletes the file from storage.
    //
    async delete(filePath: string): Promise<void> {
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
            if (this.verbose) {
                throw new WrappedError(`Failed to delete ${filePath}: ${err.message}`, { cause: err });
            }
            throw err;
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
}