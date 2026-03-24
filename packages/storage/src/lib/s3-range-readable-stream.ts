import { Readable } from "node:stream";
import { GetObjectCommand, S3Client } from "@aws-sdk/client-s3";

//
// Default chunk size for range requests: 10 MB.
//
const DEFAULT_CHUNK_SIZE = 10 * 1024 * 1024;

//
// A Node.js Readable stream that fetches an S3 object in fixed-size chunks
// using HTTP range requests. Each chunk is fully consumed before the next
// request is made, so no S3 response stream is held open between reads.
// This prevents the memory leaks caused by holding a long-lived S3 body stream.
//
export class S3RangeReadableStream extends Readable {

    //
    // The current byte offset into the file.
    //
    private offset: number = 0;

    //
    // The total size of the file in bytes, extracted from the first range response.
    //
    private fileSize: number | undefined;

    //
    // True while a range request is in flight, to prevent concurrent fetches.
    //
    private fetching: boolean = false;

    constructor(
        private readonly s3: S3Client,
        private readonly bucket: string,
        private readonly key: string,
        private readonly chunkSize: number = DEFAULT_CHUNK_SIZE
    ) {
        super();
    }

    //
    // Called by Node.js when the consumer is ready for more data.
    // Fetches the next chunk via a range request and pushes it downstream.
    //
    async _read(): Promise<void> {
        if (this.fetching) {
            return;
        }

        // If we know the file size and have read all bytes, signal end-of-stream.
        if (this.fileSize !== undefined && this.offset >= this.fileSize) {
            this.push(null);
            return;
        }

        this.fetching = true;

        try {
            const rangeStart = this.offset;
            const rangeEnd = rangeStart + this.chunkSize - 1;

            const response = await this.s3.send(new GetObjectCommand({
                Bucket: this.bucket,
                Key: this.key,
                Range: `bytes=${rangeStart}-${rangeEnd}`,
            }));

            if (this.fileSize === undefined && response.ContentRange) {
                const match = response.ContentRange.match(/\/(\d+)$/);
                if (match) {
                    this.fileSize = parseInt(match[1], 10);
                }
            }

            if (!response.Body) {
                this.push(null);
                return;
            }

            const bodyBytes = await response.Body.transformToByteArray();
            this.offset += bodyBytes.length;

            if (this.destroyed) {
                return;
            }

            this.push(Buffer.from(bodyBytes));

            // If this chunk brings us to the end of the file, signal end-of-stream.
            if (this.fileSize !== undefined && this.offset >= this.fileSize) {
                this.push(null);
            }
        }
        catch (err: any) {
            if (!this.destroyed) {
                this.destroy(err);
            }
        }
        finally {
            this.fetching = false;
        }
    }
}
