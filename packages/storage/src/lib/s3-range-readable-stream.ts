import { Readable } from "node:stream";
import { GetObjectCommand, S3Client } from "@aws-sdk/client-s3";
import { retry } from "utils";

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
// Per-attempt timeout for downloading a single chunk (5 minutes).
// Covers both the S3 request and the full body read.
//
const CHUNK_TIMEOUT = 5 * 60 * 1_000;

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
    // Index into CHUNK_SIZES for the next request. Advances when a chunk fails
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
    // Each attempt is raced against CHUNK_TIMEOUT; on failure the chunk size
    // is reduced before the next attempt.
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
            // Track the chunk index used by each attempt so we can persist the
            // successful (or last-attempted) index after retry() returns.
            let successfulChunkIndex = this.chunkSizeIndex;
            let nextChunkIndex = this.chunkSizeIndex;

            //
            // Retry getting the next chunk 3 times.
            // We down size the chunk size each time just in case it's a memory issue.
            // It could also be a connectivity issue.
            //
            const chunkData = await retry(async (): Promise<Uint8Array | undefined> => {
                successfulChunkIndex = nextChunkIndex;
                nextChunkIndex = Math.min(nextChunkIndex + 1, CHUNK_SIZES.length - 1);

                const chunkSize = CHUNK_SIZES[successfulChunkIndex];
                const rangeStart = this.offset;
                const rangeEnd = rangeStart + chunkSize - 1;

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
                    return undefined;
                }

                return await response.Body.transformToByteArray();
            }, 3, 100, 2, CHUNK_TIMEOUT);

            // Persist the chunk size that succeeded so future chunks use the same or smaller size.
            this.chunkSizeIndex = successfulChunkIndex;

            if (!chunkData) {
                this.push(null);
                return;
            }

            this.offset += chunkData.length;

            if (this.destroyed) {
                return;
            }

            this.push(Buffer.from(chunkData));

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
