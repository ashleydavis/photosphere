import { Readable } from "stream";
import { S3Client } from "@aws-sdk/client-s3";
import { S3RangeReadableStream } from "../lib/s3-range-readable-stream";

//
// Collects a readable stream into a single Buffer.
//
function streamToBuffer(stream: Readable): Promise<Buffer> {
    const chunks: Buffer[] = [];
    return new Promise((resolve, reject) => {
        stream.on("data", (chunk: Buffer) => chunks.push(chunk));
        stream.on("end", () => resolve(Buffer.concat(chunks)));
        stream.on("error", reject);
    });
}

//
// Builds a mock S3 range response for a slice of data.
//
function makeRangeResponse(slice: Buffer, totalSize: number, rangeStart: number) {
    const rangeEnd = rangeStart + slice.length - 1;
    return {
        ContentRange: `bytes ${rangeStart}-${rangeEnd}/${totalSize}`,
        Body: {
            transformToByteArray: async () => new Uint8Array(slice),
        },
    };
}

//
// Creates an S3Client mock whose send() method returns successive range responses
// by slicing the provided data according to the Range header in each request.
//
function makeMockS3(data: Buffer): { s3: S3Client; callCount: () => number } {
    let calls = 0;
    const mockSend = jest.fn().mockImplementation((command: any) => {
        calls++;
        const rangeHeader: string = command.input.Range as string;
        const match = rangeHeader.match(/bytes=(\d+)-(\d+)/);
        if (!match) {
            return Promise.reject(new Error("Invalid Range header"));
        }
        const start = parseInt(match[1], 10);
        const end = Math.min(parseInt(match[2], 10), data.length - 1);
        if (start >= data.length) {
            return Promise.reject(Object.assign(new Error("NoSuchKey"), { name: "NoSuchKey" }));
        }
        const slice = data.subarray(start, end + 1);
        return Promise.resolve(makeRangeResponse(slice, data.length, start));
    });
    const s3 = { send: mockSend } as unknown as S3Client;
    return { s3, callCount: () => calls };
}

describe("S3RangeReadableStream", () => {

    test("reads a small file smaller than one chunk", async () => {
        const data = Buffer.from("hello world");
        const { s3 } = makeMockS3(data);
        const stream = new S3RangeReadableStream(s3, "my-bucket", "my-key", 10 * 1024 * 1024);
        const result = await streamToBuffer(stream);
        expect(result).toEqual(data);
    });

    test("reads a file that spans exactly two chunks", async () => {
        const chunkSize = 16;
        const data = Buffer.alloc(chunkSize * 2, 0xab);
        const { s3, callCount } = makeMockS3(data);
        const stream = new S3RangeReadableStream(s3, "my-bucket", "my-key", chunkSize);
        const result = await streamToBuffer(stream);
        expect(result).toEqual(data);
        expect(callCount()).toBe(2);
    });

    test("reads a file that does not divide evenly into chunks", async () => {
        const chunkSize = 10;
        const data = Buffer.alloc(25, 0xcd);
        const { s3, callCount } = makeMockS3(data);
        const stream = new S3RangeReadableStream(s3, "my-bucket", "my-key", chunkSize);
        const result = await streamToBuffer(stream);
        expect(result).toEqual(data);
        expect(callCount()).toBe(3);
    });

    test("reads an empty file", async () => {
        const data = Buffer.alloc(0);
        let calls = 0;
        const mockSend = jest.fn().mockImplementation(() => {
            calls++;
            return Promise.resolve({
                ContentRange: "bytes 0-0/0",
                Body: {
                    transformToByteArray: async () => new Uint8Array(0),
                },
            });
        });
        const s3 = { send: mockSend } as unknown as S3Client;
        const stream = new S3RangeReadableStream(s3, "my-bucket", "my-key", 10);
        const result = await streamToBuffer(stream);
        expect(result).toEqual(data);
    });

    test("emits an error when S3 returns an error", async () => {
        const mockSend = jest.fn().mockRejectedValue(Object.assign(new Error("S3 unavailable"), { name: "ServiceUnavailable" }));
        const s3 = { send: mockSend } as unknown as S3Client;
        const stream = new S3RangeReadableStream(s3, "my-bucket", "my-key");
        await expect(streamToBuffer(stream)).rejects.toThrow("S3 unavailable");
    });

    test("does not make additional requests after being destroyed", async () => {
        const chunkSize = 4;
        const data = Buffer.alloc(16, 0xff);
        let calls = 0;
        const mockSend = jest.fn().mockImplementation((command: any) => {
            calls++;
            const rangeHeader: string = command.input.Range as string;
            const match = rangeHeader.match(/bytes=(\d+)-(\d+)/)!;
            const start = parseInt(match[1], 10);
            const end = Math.min(parseInt(match[2], 10), data.length - 1);
            const slice = data.subarray(start, end + 1);
            return Promise.resolve(makeRangeResponse(slice, data.length, start));
        });
        const s3 = { send: mockSend } as unknown as S3Client;
        const stream = new S3RangeReadableStream(s3, "my-bucket", "my-key", chunkSize);

        await new Promise<void>((resolve, reject) => {
            stream.once("data", () => {
                stream.destroy();
                resolve();
            });
            stream.on("error", reject);
        });

        const callsAfterDestroy = calls;
        // Wait a tick to confirm no additional requests were made
        await new Promise(resolve => setTimeout(resolve, 20));
        expect(calls).toBe(callsAfterDestroy);
    });

    test("handles missing Body in response gracefully", async () => {
        const mockSend = jest.fn().mockResolvedValue({
            ContentRange: "bytes 0-9/10",
            Body: undefined,
        });
        const s3 = { send: mockSend } as unknown as S3Client;
        const stream = new S3RangeReadableStream(s3, "my-bucket", "my-key");
        const result = await streamToBuffer(stream);
        expect(result.length).toBe(0);
    });
});
