import { Readable } from "stream";
import { S3Client } from "@aws-sdk/client-s3";
import { S3RangeReadableStream } from "../lib/s3-range-readable-stream";

//
// The three chunk sizes the stream attempts, in order: 100 MB, 20 MB, 10 MB.
//
const CHUNK_SIZE_LARGE  = 100 * 1024 * 1024;
const CHUNK_SIZE_MEDIUM =  20 * 1024 * 1024;
const CHUNK_SIZE_SMALL  =  10 * 1024 * 1024;

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

    test("reads a small file in a single chunk", async () => {
        const data = Buffer.from("hello world");
        const { s3, callCount } = makeMockS3(data);
        const stream = new S3RangeReadableStream(s3, "my-bucket", "my-key");
        const result = await streamToBuffer(stream);
        expect(result).toEqual(data);
        expect(callCount()).toBe(1);
    });

    test("ends the stream on a short read when the response carries no Content-Range", async () => {
        // The file size is normally learned from Content-Range. It is not always available: on the
        // mobile worker the response reaches the SDK through the native HTTP bridge without it. A
        // range that comes back shorter than it asked for is then the only signal that the end of the
        // object has been reached, and without acting on it the stream requests ranges for ever and
        // never ends, which hung every read from S3 on a device until its caller timed out.
        const data = Buffer.from("a short object with no content range");
        let calls = 0;
        const mockSend = jest.fn().mockImplementation((command: any) => {
            calls += 1;
            const match = (command.input.Range as string).match(/bytes=(\d+)-(\d+)/);
            const start = parseInt(match![1], 10);
            const end = Math.min(parseInt(match![2], 10), data.length - 1);
            const slice = data.subarray(start, end + 1);
            return Promise.resolve({
                // No ContentRange, so the stream cannot learn the file size.
                Body: {
                    transformToByteArray: async () => new Uint8Array(slice),
                },
            });
        });
        const s3 = { send: mockSend } as unknown as S3Client;

        const stream = new S3RangeReadableStream(s3, "my-bucket", "my-key");
        const result = await streamToBuffer(stream);

        expect(result).toEqual(data);
        expect(calls).toBe(1);
    });

    test("reads an empty file", async () => {
        const mockSend = jest.fn().mockResolvedValue({
            ContentRange: "bytes 0-0/0",
            Body: {
                transformToByteArray: async () => new Uint8Array(0),
            },
        });
        const s3 = { send: mockSend } as unknown as S3Client;
        const stream = new S3RangeReadableStream(s3, "my-bucket", "my-key");
        const result = await streamToBuffer(stream);
        expect(result.length).toBe(0);
    });

    test("emits an error when all chunk sizes fail", async () => {
        const mockSend = jest.fn().mockRejectedValue(Object.assign(new Error("S3 unavailable"), { name: "ServiceUnavailable" }));
        const s3 = { send: mockSend } as unknown as S3Client;
        const stream = new S3RangeReadableStream(s3, "my-bucket", "my-key");
        await expect(streamToBuffer(stream)).rejects.toThrow("S3 unavailable");
    });

    test("tries all three chunk sizes before emitting error", async () => {
        const mockSend = jest.fn().mockRejectedValue(new Error("network failure"));
        const s3 = { send: mockSend } as unknown as S3Client;
        const stream = new S3RangeReadableStream(s3, "my-bucket", "my-key");
        await expect(streamToBuffer(stream)).rejects.toThrow("network failure");
        expect(mockSend).toHaveBeenCalledTimes(3);
    });

    test("falls back to medium chunk size when large chunk fails", async () => {
        const data = Buffer.from("hello world");
        const mockSend = jest.fn().mockImplementation((command: any) => {
            const rangeHeader: string = command.input.Range as string;
            const match = rangeHeader.match(/bytes=(\d+)-(\d+)/)!;
            const start = parseInt(match[1], 10);
            const end = parseInt(match[2], 10);
            if (end - start >= CHUNK_SIZE_LARGE - 1) {
                return Promise.reject(new Error("chunk too large"));
            }
            const sliceEnd = Math.min(end, data.length - 1);
            const slice = data.subarray(start, sliceEnd + 1);
            return Promise.resolve(makeRangeResponse(slice, data.length, start));
        });
        const s3 = { send: mockSend } as unknown as S3Client;
        const stream = new S3RangeReadableStream(s3, "my-bucket", "my-key");
        const result = await streamToBuffer(stream);
        expect(result).toEqual(data);
        // First call fails (100 MB), second succeeds (20 MB)
        expect(mockSend).toHaveBeenCalledTimes(2);
        const secondRange: string = mockSend.mock.calls[1][0].input.Range;
        expect(secondRange).toBe(`bytes=0-${CHUNK_SIZE_MEDIUM - 1}`);
    });

    test("falls back to small chunk size when large and medium chunks fail", async () => {
        const data = Buffer.from("hello world");
        const mockSend = jest.fn().mockImplementation((command: any) => {
            const rangeHeader: string = command.input.Range as string;
            const match = rangeHeader.match(/bytes=(\d+)-(\d+)/)!;
            const start = parseInt(match[1], 10);
            const end = parseInt(match[2], 10);
            if (end - start >= CHUNK_SIZE_MEDIUM - 1) {
                return Promise.reject(new Error("chunk failed"));
            }
            const sliceEnd = Math.min(end, data.length - 1);
            const slice = data.subarray(start, sliceEnd + 1);
            return Promise.resolve(makeRangeResponse(slice, data.length, start));
        });
        const s3 = { send: mockSend } as unknown as S3Client;
        const stream = new S3RangeReadableStream(s3, "my-bucket", "my-key");
        const result = await streamToBuffer(stream);
        expect(result).toEqual(data);
        // First two calls fail (100 MB, 20 MB), third succeeds (10 MB)
        expect(mockSend).toHaveBeenCalledTimes(3);
        const thirdRange: string = mockSend.mock.calls[2][0].input.Range;
        expect(thirdRange).toBe(`bytes=0-${CHUNK_SIZE_SMALL - 1}`);
    });

    test("uses the smaller chunk size for all subsequent chunks after a fallback", async () => {
        const data = Buffer.alloc(25, 0xaa);
        let callCount = 0;
        const mockSend = jest.fn().mockImplementation((command: any) => {
            callCount++;
            const rangeHeader: string = command.input.Range as string;
            const match = rangeHeader.match(/bytes=(\d+)-(\d+)/)!;
            const start = parseInt(match[1], 10);
            const end = parseInt(match[2], 10);
            // Only fail the very first request (100 MB chunk)
            if (callCount === 1) {
                return Promise.reject(new Error("first chunk failed"));
            }
            const sliceEnd = Math.min(end, data.length - 1);
            const slice = data.subarray(start, sliceEnd + 1);
            return Promise.resolve(makeRangeResponse(slice, data.length, start));
        });
        const s3 = { send: mockSend } as unknown as S3Client;
        const stream = new S3RangeReadableStream(s3, "my-bucket", "my-key");
        const result = await streamToBuffer(stream);
        expect(result).toEqual(data);
        // 1 failed large + 1 medium chunk that covers the whole 25-byte file
        expect(mockSend).toHaveBeenCalledTimes(2);
        const secondRange: string = mockSend.mock.calls[1][0].input.Range;
        expect(secondRange).toBe(`bytes=0-${CHUNK_SIZE_MEDIUM - 1}`);
    });

    test("does not make additional requests after being destroyed", async () => {
        const data = Buffer.alloc(200 * 1024 * 1024, 0xff); // 200 MB — spans two 100 MB chunks
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
        const stream = new S3RangeReadableStream(s3, "my-bucket", "my-key");

        await new Promise<void>((resolve, reject) => {
            stream.once("data", () => {
                stream.destroy();
                resolve();
            });
            stream.on("error", reject);
        });

        const callsAfterDestroy = calls;
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
