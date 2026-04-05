import { Readable } from "stream";
import { LazyOriginStorage } from "../../lib/lazy-origin-storage";
import type { IFileInfo, IListResult, IStorage, IWriteLockInfo } from "storage";

//
// Builds a minimal mock IStorage. Only the methods used by LazyOriginStorage tests
// need real implementations; the rest throw so accidental calls are obvious.
//
function makeMockStorage(files: Map<string, Buffer> = new Map()): IStorage {
    return {
        location: "mock://local",

        async isEmpty(_path: string): Promise<boolean> {
            throw new Error("not implemented");
        },

        async listFiles(_path: string, _max: number, _next?: string): Promise<IListResult> {
            throw new Error("not implemented");
        },

        async listDirs(_path: string, _max: number, _next?: string): Promise<IListResult> {
            throw new Error("not implemented");
        },

        async fileExists(filePath: string): Promise<boolean> {
            return files.has(filePath);
        },

        async dirExists(_dirPath: string): Promise<boolean> {
            throw new Error("not implemented");
        },

        async info(_filePath: string): Promise<IFileInfo | undefined> {
            throw new Error("not implemented");
        },

        async read(filePath: string): Promise<Buffer | undefined> {
            return files.get(filePath);
        },

        async write(filePath: string, _contentType: string | undefined, data: Buffer): Promise<void> {
            files.set(filePath, data);
        },

        async readStream(filePath: string): Promise<Readable> {
            const data = files.get(filePath);
            if (!data) {
                throw new Error(`File not found: ${filePath}`);
            }
            return Readable.from(data);
        },

        async writeStream(filePath: string, _contentType: string | undefined, inputStream: NodeJS.ReadableStream): Promise<void> {
            const chunks: Buffer[] = [];
            for await (const chunk of inputStream) {
                chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
            }
            files.set(filePath, Buffer.concat(chunks));
        },

        async deleteFile(filePath: string): Promise<void> {
            files.delete(filePath);
        },

        async deleteDir(_dirPath: string): Promise<void> {
            throw new Error("not implemented");
        },

        async copyTo(_srcPath: string, _destPath: string): Promise<void> {
            throw new Error("not implemented");
        },

        async checkWriteLock(_filePath: string): Promise<IWriteLockInfo | undefined> {
            throw new Error("not implemented");
        },

        async acquireWriteLock(_filePath: string, _owner: string): Promise<boolean> {
            throw new Error("not implemented");
        },

        async releaseWriteLock(_filePath: string): Promise<void> {
            throw new Error("not implemented");
        },

        async refreshWriteLock(_filePath: string, _owner: string): Promise<void> {
            throw new Error("not implemented");
        },
    };
}

//
// Reads all bytes from a Readable stream into a Buffer.
//
async function readAll(stream: Readable): Promise<Buffer> {
    const chunks: Buffer[] = [];
    for await (const chunk of stream) {
        chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
    }
    return Buffer.concat(chunks);
}

test("read() returns local data without calling origin when local has the file", async () => {
    const localFiles = new Map<string, Buffer>([["foo.txt", Buffer.from("local")]]);
    const originFiles = new Map<string, Buffer>([["foo.txt", Buffer.from("origin")]]);
    const local = makeMockStorage(localFiles);
    const origin = makeMockStorage(originFiles);

    let originReadCalled = false;
    const originalOriginRead = origin.read.bind(origin);
    origin.read = async (filePath: string) => {
        originReadCalled = true;
        return originalOriginRead(filePath);
    };

    const lazy = new LazyOriginStorage(local, origin);
    const result = await lazy.read("foo.txt");

    expect(result?.toString()).toBe("local");
    expect(originReadCalled).toBe(false);
});

test("read() fetches from origin when local returns undefined, caches locally, and returns data", async () => {
    const localFiles = new Map<string, Buffer>();
    const originFiles = new Map<string, Buffer>([["bar.txt", Buffer.from("from-origin")]]);
    const local = makeMockStorage(localFiles);
    const origin = makeMockStorage(originFiles);

    const lazy = new LazyOriginStorage(local, origin);
    const result = await lazy.read("bar.txt");

    expect(result?.toString()).toBe("from-origin");

    // File should now be cached locally.
    const cached = localFiles.get("bar.txt");
    expect(cached?.toString()).toBe("from-origin");
});

test("read() returns undefined when both local and origin have nothing", async () => {
    const lazy = new LazyOriginStorage(makeMockStorage(), makeMockStorage());
    const result = await lazy.read("missing.txt");
    expect(result).toBeUndefined();
});

test("readStream() returns local stream directly when file exists locally", async () => {
    const localFiles = new Map<string, Buffer>([["img.jpg", Buffer.from("localdata")]]);
    const originFiles = new Map<string, Buffer>([["img.jpg", Buffer.from("origindata")]]);
    const origin = makeMockStorage(originFiles);

    let originReadStreamCalled = false;
    origin.readStream = async (_filePath: string): Promise<Readable> => {
        originReadStreamCalled = true;
        throw new Error("should not be called");
    };

    const lazy = new LazyOriginStorage(makeMockStorage(localFiles), origin);
    const stream = await lazy.readStream("img.jpg");
    const data = await readAll(stream);

    expect(data.toString()).toBe("localdata");
    expect(originReadStreamCalled).toBe(false);
});

test("readStream() fetches from origin and tees when file is missing locally", async () => {
    const localFiles = new Map<string, Buffer>();
    const originFiles = new Map<string, Buffer>([["vid.mp4", Buffer.from("videodata")]]);
    const local = makeMockStorage(localFiles);
    const origin = makeMockStorage(originFiles);

    const lazy = new LazyOriginStorage(local, origin);
    const stream = await lazy.readStream("vid.mp4");
    const data = await readAll(stream);

    expect(data.toString()).toBe("videodata");

    // Allow the background cache write to complete.
    await new Promise<void>(resolve => setImmediate(resolve));

    // File should now be cached locally.
    const cached = localFiles.get("vid.mp4");
    expect(cached?.toString()).toBe("videodata");
});

test("readStream() streams data correctly even if local cache write fails", async () => {
    const originFiles = new Map<string, Buffer>([["doc.pdf", Buffer.from("pdfdata")]]);
    const local = makeMockStorage();
    const origin = makeMockStorage(originFiles);

    // Make the local writeStream always reject.
    local.writeStream = async () => {
        throw new Error("disk full");
    };

    const lazy = new LazyOriginStorage(local, origin);
    const stream = await lazy.readStream("doc.pdf");
    const data = await readAll(stream);

    expect(data.toString()).toBe("pdfdata");
});

test("write() writes to local only and never touches origin", async () => {
    const localFiles = new Map<string, Buffer>();
    const originFiles = new Map<string, Buffer>();
    const local = makeMockStorage(localFiles);
    const origin = makeMockStorage(originFiles);

    let originWriteCalled = false;
    origin.write = async () => {
        originWriteCalled = true;
    };

    const lazy = new LazyOriginStorage(local, origin);
    await lazy.write("out.txt", undefined, Buffer.from("hello"));

    expect(localFiles.get("out.txt")?.toString()).toBe("hello");
    expect(originWriteCalled).toBe(false);
});

test("writeStream() writes to local only and never touches origin", async () => {
    const localFiles = new Map<string, Buffer>();
    const local = makeMockStorage(localFiles);
    const origin = makeMockStorage();

    let originWriteStreamCalled = false;
    origin.writeStream = async () => {
        originWriteStreamCalled = true;
    };

    const lazy = new LazyOriginStorage(local, origin);
    await lazy.writeStream("stream.bin", undefined, Readable.from(Buffer.from("streamdata")));

    expect(localFiles.get("stream.bin")?.toString()).toBe("streamdata");
    expect(originWriteStreamCalled).toBe(false);
});
