import { PassThrough } from "stream";
import type { Readable } from "stream";
import type { IFileInfo, IListResult, IStorage, IWriteLockInfo } from "storage";

//
// A storage wrapper that transparently fetches missing files from an origin storage
// and caches them locally on first access.
//
// Read operations check local first; if the file is absent, they fetch from origin,
// cache the result locally, and return it to the caller.
//
// Write operations always go to local only — the origin is never written to.
//
// fileExists / dirExists / info / list operations query local only; they do not
// trigger a fetch, so callers that check existence before reading will still get
// the lazy-fetch behaviour on the subsequent read call.
//
export class LazyOriginStorage implements IStorage {

    //
    // Local storage that acts as the primary read/write target and cache.
    //
    private readonly local: IStorage;

    //
    // Origin storage that is consulted when a file is missing locally.
    //
    private readonly origin: IStorage;

    constructor(local: IStorage, origin: IStorage) {
        this.local = local;
        this.origin = origin;
    }

    get location(): string {
        return this.local.location;
    }

    async isEmpty(path: string): Promise<boolean> {
        return this.local.isEmpty(path);
    }

    async listFiles(path: string, max: number, next?: string): Promise<IListResult> {
        return this.local.listFiles(path, max, next);
    }

    async listDirs(path: string, max: number, next?: string): Promise<IListResult> {
        return this.local.listDirs(path, max, next);
    }

    async fileExists(filePath: string): Promise<boolean> {
        return this.local.fileExists(filePath);
    }

    async dirExists(dirPath: string): Promise<boolean> {
        return this.local.dirExists(dirPath);
    }

    async info(filePath: string): Promise<IFileInfo | undefined> {
        return this.local.info(filePath);
    }

    //
    // Reads a file from local storage. If the file is absent locally, fetches it from
    // origin, caches it locally, and returns the data.
    //
    async read(filePath: string): Promise<Buffer | undefined> {
        const localData = await this.local.read(filePath);
        if (localData !== undefined) {
            return localData;
        }

        const originData = await this.origin.read(filePath);
        if (originData === undefined) {
            return undefined;
        }

        await this.local.write(filePath, undefined, originData);
        return originData;
    }

    async write(filePath: string, contentType: string | undefined, data: Buffer): Promise<void> {
        await this.local.write(filePath, contentType, data);
    }

    //
    // Streams a file from local storage. If the file is absent locally, fetches it from
    // origin using a tee stream: one branch writes to the local cache, the other is
    // returned to the caller. The origin stream is never fully buffered in memory, which
    // is required for large files such as 7 GB videos.
    //
    // Cache write errors are non-fatal — the caller's stream is unaffected.
    //
    async readStream(filePath: string): Promise<Readable> {
        if (await this.local.fileExists(filePath)) {
            return this.local.readStream(filePath);
        }

        const originStream = await this.origin.readStream(filePath);
        const cacheStream = new PassThrough();
        const callerStream = new PassThrough();

        //
        // Tee: forward data from origin to both PassThrough streams with backpressure.
        //
        originStream.on("data", (chunk: Buffer) => {
            const cacheFull = !cacheStream.write(chunk);
            const callerFull = !callerStream.write(chunk);
            if (cacheFull || callerFull) {
                originStream.pause();
            }
        });

        cacheStream.on("drain", () => {
            if (!callerStream.writableNeedDrain) {
                originStream.resume();
            }
        });

        callerStream.on("drain", () => {
            if (!cacheStream.writableNeedDrain) {
                originStream.resume();
            }
        });

        originStream.on("end", () => {
            cacheStream.end();
            callerStream.end();
        });

        originStream.on("error", (err: Error) => {
            cacheStream.destroy(err);
            callerStream.destroy(err);
        });

        //
        // Cache in the background; errors are swallowed so the caller is not affected.
        //
        this.local.writeStream(filePath, undefined, cacheStream).catch(() => {});

        return callerStream;
    }

    async writeStream(
        filePath: string,
        contentType: string | undefined,
        inputStream: NodeJS.ReadableStream,
        contentLength?: number
    ): Promise<void> {
        await this.local.writeStream(filePath, contentType, inputStream, contentLength);
    }

    async deleteFile(filePath: string): Promise<void> {
        await this.local.deleteFile(filePath);
    }

    async deleteDir(dirPath: string): Promise<void> {
        await this.local.deleteDir(dirPath);
    }

    async copyTo(srcPath: string, destPath: string): Promise<void> {
        await this.local.copyTo(srcPath, destPath);
    }

    async checkWriteLock(filePath: string): Promise<IWriteLockInfo | undefined> {
        return this.local.checkWriteLock(filePath);
    }

    async acquireWriteLock(filePath: string, owner: string): Promise<boolean> {
        return this.local.acquireWriteLock(filePath, owner);
    }

    async releaseWriteLock(filePath: string): Promise<void> {
        await this.local.releaseWriteLock(filePath);
    }

    async refreshWriteLock(filePath: string, owner: string): Promise<void> {
        await this.local.refreshWriteLock(filePath, owner);
    }
}
