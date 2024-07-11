import { Readable } from "stream";
import aws from "aws-sdk";
import { IFileInfo, IListResult, IStorage } from "./storage";

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
    // The S3 bucket in which to store files.
    //
    private bucket!: string;
    
    //
    // AWS S3 interface.
    //
    private s3!: aws.S3;

    constructor() {
        this.bucket = process.env.AWS_BUCKET as string;
        if (this.bucket === undefined) {
            throw new Error(`Set the AWS bucket through the environment variable AWS_BUCKET.`);
        }

        this.s3 = new aws.S3({
            endpoint: process.env.AWS_ENDPOINT,
        });
    }

    //
    // List files in storage.
    //
    async list(path: string, max: number, next?: string): Promise<IListResult> {    
        const listParams: aws.S3.Types.ListObjectsV2Request = {
            Bucket: this.bucket,
            Prefix: `${path}/`,
            MaxKeys: max,
            ContinuationToken: next,
        };

        const response = await this.s3.listObjectsV2(listParams).promise();
        const fileNames = response.Contents?.map(item => {
            const nameParts = item.Key!.split("/");
            return nameParts[nameParts.length - 1]; // The last part is the file name or asset ID.
        }) || [];

        return {
            fileNames,
            next: response.NextContinuationToken,
        };
    }

    //
    // Returns true if the specified file exists.
    //
    async exists(path: string, fileName: string): Promise<boolean> {
        const headParams: aws.S3.Types.HeadObjectRequest = {
            Bucket: this.bucket,
            Key: `${path}/${fileName}`,
        };
        try {
            await this.s3.headObject(headParams).promise();
            return true;
        }
        catch (err: any) {
            if (err.code === 'NotFound') {
                return false;
            }
            throw err;
        }
    }

    //
    // Gets info about an asset.
    //
    async info(path: string, fileName: string): Promise<IFileInfo | undefined> {
        const headParams: aws.S3.Types.HeadObjectRequest = {
            Bucket: this.bucket,
            Key: `${path}/${fileName}`,
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
            throw err;
        }
    }

    //
    // Reads a file from storage.
    // Returns undefined if the file doesn't exist.
    //
    async read(path: string, fileName: string): Promise<Buffer | undefined> {
        const getParams: aws.S3.Types.GetObjectRequest = {
            Bucket: this.bucket, 
            Key: `${path}/${fileName}`,
        };
        try {
            const getObjectOutput = await this.s3.getObject(getParams).promise();
            return getObjectOutput.Body as Buffer;
        }
        catch (err: any) {
            if (err.code === 'NoSuchKey') {
                return undefined;
            }
            throw err;            
        }
    }

    //
    // Writes a file to storage.
    //
    async write(path: string, fileName: string, contentType: string, data: Buffer): Promise<void> {
        const params: aws.S3.Types.PutObjectRequest = {
            Bucket: this.bucket,
            Key: `${path}/${fileName}`,
            Body: data,
            ContentType: contentType,
        };    
        await this.s3.upload(params).promise();
    }

    //
    // Streams a file from stroage.
    //
    readStream(path: string, fileName: string): Readable {
        const getParams: aws.S3.Types.GetObjectRequest = {
            Bucket: this.bucket, 
            Key: `${path}/${fileName}`,
        };
        return this.s3.getObject(getParams).createReadStream();
    }

    //
    // Writes an input stream to storage.
    //
    async writeStream(path: string, fileName: string, contentType: string, inputStream: Readable): Promise<void> {
        const params: aws.S3.Types.PutObjectRequest = {
            Bucket: this.bucket,
            Key: `${path}/${fileName}`,
            Body: inputStream,
            ContentType: contentType,
        };    
        await this.s3.upload(params).promise();
    }

    //
    // Deletes the file from storage.
    //
    async delete(path: string, fileName: string): Promise<void> {
        const deleteParams: aws.S3.Types.DeleteObjectRequest = {
            Bucket: this.bucket,
            Key: `${path}/${fileName}`,
        };
        await this.s3.deleteObject(deleteParams).promise();
    }

}