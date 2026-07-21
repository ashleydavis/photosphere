//
// The `@aws-sdk/lib-storage` module for the mobile worker bundle.
//
// CloudStorage imports `Upload` for large S3 uploads. In the AWS SDK this chunks the object into a
// multipart upload; here it is implemented as a single PutObject via the mobile worker's S3 client
// (see aws-s3.ts). Multipart is deliberately not implemented yet: S3's single-PUT limit is 5GB, which
// no thumbnail or display asset approaches. Originals can exceed it; that is a recorded known limit,
// and adding multipart without also fixing the read path (whole-file memory model) buys nothing.
//

import { Buffer } from "buffer";
import { S3Client, PutObjectCommand } from "./aws-s3";

//
// A stream-like upload body: an object that emits `data`/`end` events (the shim's Readable).
//
interface IReadableBody {
    // Registers an event listener for `data`/`end`/`error`.
    on(event: string, listener: (arg?: unknown) => void): void;
}

//
// The Upload params subset CloudStorage passes.
//
interface IUploadParams {
    // The target bucket.
    Bucket: string;

    // The target key.
    Key: string;

    // The object body: a Buffer/Uint8Array, or a readable stream that emits `data`/`end`.
    Body: Buffer | Uint8Array | IReadableBody;

    // The object content type.
    ContentType?: string;

    // The object content length (informational; the single PUT uses the buffered length).
    ContentLength?: number;
}

//
// The Upload options CloudStorage passes.
//
interface IUploadOptions {
    // The S3 client to upload through.
    client: S3Client;

    // The upload params (bucket, key, body, content type).
    params: IUploadParams;

    // The multipart part size (ignored: single PUT).
    partSize?: number;

    // The multipart queue size (ignored: single PUT).
    queueSize?: number;
}

//
// Collects a stream-like body into a single Buffer (the whole-file memory model).
//
function collectBody(body: Buffer | Uint8Array | IReadableBody): Promise<Buffer> {
    if (Buffer.isBuffer(body)) {
        return Promise.resolve(body);
    }
    if (body instanceof Uint8Array) {
        return Promise.resolve(Buffer.from(body));
    }
    return new Promise<Buffer>((resolve, reject) => {
        const chunks: Buffer[] = [];
        body.on("data", chunk => {
            chunks.push(Buffer.from(chunk as Buffer));
        });
        body.on("end", () => {
            resolve(Buffer.concat(chunks));
        });
        body.on("error", error => {
            reject(error as Error);
        });
    });
}

//
// Uploads an S3 object as a single PutObject. `done()` matches the AWS SDK's Upload.done() surface.
//
export class Upload {
    //
    // The upload options (client + params).
    //
    private readonly options: IUploadOptions;

    //
    // Builds an upload; the actual PUT happens in done().
    //
    constructor(options: IUploadOptions) {
        this.options = options;
    }

    //
    // Performs the upload as a single PutObject and resolves when it completes.
    //
    async done(): Promise<void> {
        const body = await collectBody(this.options.params.Body);
        await this.options.client.send(new PutObjectCommand({
            Bucket: this.options.params.Bucket,
            Key: this.options.params.Key,
            Body: body,
            ContentType: this.options.params.ContentType,
            ContentLength: body.length,
        }));
    }
}
