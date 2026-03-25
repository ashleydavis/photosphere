import { Readable } from "node:stream";
import { GetObjectCommand, S3Client } from "@aws-sdk/client-s3";

//
// Chunk sizes to attempt for range requests, in order.
// On failure the stream falls back to the next smaller size.
//
const CHUNK_SIZES = [
    100 * 1024 * 1024, // 100 MB — start large to minimise round-trips
     20 * 1024 * 1024, // 20 MB
     10 * 1024 * 1024, // 10 MB
];

//
// A Node.js Readable stream that fetches an S3 object in fixed-size chunks
// using HTTP range requests. Each chunk is fully consumed before the next
// request is made, so no S3 response stream is held open between reads.
// This prevents the memory leaks caused by holding a long-lived S3 body stream.
//
// NOTE: Breaking up an S3 download into multiple HTTP requests makes it really slow.
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

    //
    // Index into CHUNK_SIZES for the current attempt. Advances on chunk failure
    // so subsequent chunks use a smaller size.
    //
    private chunkSizeIndex: number = 0;

    constructor(
        private readonly s3: S3Client,
        private readonly bucket: string,
        private readonly key: string,
    ) {
        super();
    }

    //
    // Called by Node.js when the consumer is ready for more data.
    // Fetches the next chunk via a range request and pushes it downstream.
    // On failure, retries the same byte range with the next smaller chunk size
    // before propagating the error.
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
            let lastError: any;

            while (this.chunkSizeIndex < CHUNK_SIZES.length) {
                const chunkSize = CHUNK_SIZES[this.chunkSizeIndex];
                const rangeStart = this.offset;
                const rangeEnd = rangeStart + chunkSize - 1;

                try {
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

                    return;
                }
                catch (err: any) {
                    lastError = err;
                    this.chunkSizeIndex++;
                }
            }

            if (!this.destroyed) {
                this.destroy(lastError);
            }
        }
        finally {
            this.fetching = false;
        }
    }
}
