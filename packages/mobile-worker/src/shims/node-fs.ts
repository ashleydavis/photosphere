//
// Mobile `fs` (sync + stream) shim.
//
// FileStorage imports `createReadStream`/`createWriteStream` from `fs`. Both are backed by the
// whole-file host bridge: createReadStream reads the whole file and emits it as one chunk;
// createWriteStream buffers written chunks and writes the whole file on end.
//

import { getFsHost, codedError, base64ToBuffer, callHost } from "./host-access";
import { Readable, Writable } from "./node-stream";
import fsPromisesModule from "./node-fs-promises";

//
// Mirrors `fs.promises`, so a caller reaching the promise API through the `fs` module gets the same
// implementation as one importing `fs/promises` directly. The AWS SDK's SSO token writer does this.
//
export const promises = fsPromisesModule;

//
// A file-backed readable stream. It carries the path it was opened from, which is what Node's
// `ReadStream` exposes and what the AWS SDK's body-length helper reads to size a file-backed body.
//
//
// How much of a file is fetched across the engine bridge at a time.
//
// A file used to come back in a single call, whatever its size, and a base64 string is a third
// bigger again than the bytes it carries. That is survivable for a photo and fatal for a video:
// syncing a real library from a Pixel 6 died on a 100MB video with "Failed to allocate a 105478648
// byte allocation ... growth limit 268435456", and every pass after it died the same way on the same
// file, so nothing beyond that video ever reached the origin.
//
// Four megabytes is a chunk small enough that its base64 copy is nothing against the heap, and large
// enough that a large file does not cost thousands of trips across the bridge.
//
const CHUNK_BYTES = 4 * 1024 * 1024;

//
// Options accepted by createReadStream: a byte range to read rather than the whole file.
//
export interface IReadStreamOptions {
    // First byte to read, inclusive.
    start?: number;

    // Last byte to read, inclusive, the way Node's fs.createReadStream defines it.
    end?: number;
}

export class ReadStream extends Readable {
    //
    // The path this stream was opened from.
    //
    readonly path: string;

    //
    // The byte range to read, when the caller asked for one rather than the whole file.
    //
    private readonly range: IReadStreamOptions;

    //
    // True once every byte asked for has been pushed, so the end is only declared once.
    //
    private hasReadFile = false;

    //
    // The next byte to read, moving through the file a chunk at a time.
    //
    private nextOffset: number | undefined = undefined;

    //
    // The last byte to read, inclusive. Worked out on the first read, from the range or the file's
    // own size.
    //
    private lastOffset = 0;

    //
    // Builds a stream over the file at the given path, WITHOUT reading it.
    //
    // The bytes are fetched on the first attempt to consume the stream, not here. That is the whole
    // point of it: reading a file across the engine bridge brings it back as a base64 string built
    // natively and decoded in the engine, so a five megabyte photo costs a seven megabyte string and
    // the decode of it. Storage recognises a file-backed stream by its path and copies the file
    // natively instead of piping it, which means for every photo taken into a database those bytes
    // were being fetched and then thrown away unread.
    //
    constructor(path: string, range: IReadStreamOptions) {
        super();
        this.path = path;
        this.range = range;
    }

    //
    // Reads the file, or the range of it that was asked for, the first time the stream is consumed.
    //
    //
    // Hands the file itself to a destination that can take one, rather than reading it.
    //
    // An upload is a file piped into an HTTP request, and the request shim can have the bytes sent
    // from disk to the socket natively. Everything else crosses the host bridge as base64, a third
    // larger than the bytes it carries, built on one side and decoded on the other: measured on a
    // Pixel 6, an upload paid that twice, once here and once on the way out, and managed about three
    // megabytes a minute with the network idle nine tenths of the time.
    //
    // A destination that cannot take a file (anything but the http shim's request) is piped the
    // ordinary way, chunk by chunk.
    //
    pipe(destination: any): any {
        if (destination && typeof destination.writeFileBody === "function") {
            const start = this.range.start ?? 0;
            const end = this.range.end !== undefined ? this.range.end : statSync(this.path).size - 1;
            if (destination.writeFileBody(this.path, start, end - start + 1)) {
                this.hasReadFile = true;
                this.emit("end");
                if (typeof destination.end === "function") {
                    destination.end();
                }
                return destination;
            }
        }

        return super.pipe(destination);
    }

    protected _read(): void {
        if (this.hasReadFile) {
            return;
        }

        if (this.nextOffset === undefined) {
            this.nextOffset = this.range.start ?? 0;

            if (this.range.end !== undefined) {
                this.lastOffset = this.range.end;
            }
            else {
                let size: number;
                try {
                    size = statSync(this.path).size;
                }
                catch (error) {
                    this.hasReadFile = true;
                    this.emit("error", error);
                    return;
                }
                this.lastOffset = size - 1;
            }
        }

        const remaining = this.lastOffset - this.nextOffset + 1;
        if (remaining <= 0) {
            this.hasReadFile = true;
            this.push(null);
            return;
        }

        const length = Math.min(remaining, CHUNK_BYTES);
        const base64 = callHost(() => getFsHost().fsReadFileRange(this.path, this.nextOffset as number, length));

        if (base64 === null || base64 === undefined) {
            this.hasReadFile = true;
            this.emit("error", codedError("ENOENT", `ENOENT: no such file or directory, open '${this.path}'`));
            return;
        }

        this.nextOffset += length;
        this.push(base64ToBuffer(base64));

        if (this.nextOffset > this.lastOffset) {
            this.hasReadFile = true;
            this.push(null);
        }
    }
}

//
// The file metadata the sync stat calls return.
//
export class Stats {
    //
    // File size in bytes.
    //
    readonly size: number;

    //
    // Last-modified time.
    //
    readonly mtime: Date;

    //
    // Whether this path is a regular file.
    //
    private readonly file: boolean;

    //
    // Whether this path is a directory.
    //
    private readonly directory: boolean;

    //
    // Builds Stats from the native stat fields.
    //
    constructor(size: number, mtimeMs: number, file: boolean, directory: boolean) {
        this.size = size;
        this.mtime = new Date(mtimeMs);
        this.file = file;
        this.directory = directory;
    }

    //
    // Returns true when the path is a regular file.
    //
    isFile(): boolean {
        return this.file;
    }

    //
    // Returns true when the path is a directory.
    //
    isDirectory(): boolean {
        return this.directory;
    }
}

//
// Creates a readable stream over a file by reading the whole file through the host bridge and
// emitting it as a single chunk. Matches the whole-file read model used across the mobile worker.
//
//
// Opens a file as a readable stream, without reading it.
//
// The existence check stays here so a missing file still fails at the point of the call, the way
// every caller of this expects. The bytes themselves are read only if something actually consumes
// the stream: see ReadStream.
//
export function createReadStream(path: string, options?: IReadStreamOptions): ReadStream {
    if (!callHost(() => getFsHost().fsAccess(path))) {
        throw codedError("ENOENT", `ENOENT: no such file or directory, open '${path}'`);
    }

    return new ReadStream(path, options ?? {});
}

//
// Reads a whole file, throwing an ENOENT-coded error when it does not exist. Mirrors fs.readFileSync:
// with an encoding it returns a string, without one the raw bytes. The native read is synchronous, so
// this needs no separate machinery.
//
export function readFileSync(path: string, encoding?: string): Buffer | string {
    const base64 = callHost(() => getFsHost().fsReadFile(path));
    if (base64 === null || base64 === undefined) {
        throw codedError("ENOENT", `ENOENT: no such file or directory, open '${path}'`);
    }

    const contents = base64ToBuffer(base64);
    if (encoding) {
        return contents.toString(encoding as BufferEncoding);
    }

    return contents;
}

//
// Returns metadata for a path, throwing an ENOENT-coded error when it does not exist. Mirrors
// fs.statSync; the native stat call is synchronous, so this needs no separate machinery.
//
export function statSync(path: string): Stats {
    const json = callHost(() => getFsHost().fsStat(path));
    if (json === null || json === undefined) {
        throw codedError("ENOENT", `ENOENT: no such file or directory, stat '${path}'`);
    }

    const parsed = JSON.parse(json);
    return new Stats(parsed.size, parsed.mtimeMs, parsed.isFile, parsed.isDirectory);
}

//
// Returns metadata for a path without following a symlink. The host bridge does not distinguish the
// two, so this is statSync, which matches fs.lstatSync for every non-symlink path.
//
export function lstatSync(path: string): Stats {
    return statSync(path);
}

//
// Returns metadata for an open file descriptor. The host bridge is path-based and hands out no file
// descriptors, so nothing can hold one; reaching this means a caller opened a file some other way.
//
export function fstatSync(fd: number): Stats {
    throw new Error(`fstatSync is NOT IMPLEMENTED in the mobile worker (called with fd ${fd}); the host bridge is path-based and issues no file descriptors.`);
}

//
// A file-backed writable stream that flushes to the host a chunk at a time.
//
// It used to buffer every chunk and write the whole file in one host call on end, which is the
// mirror image of the read model that `ReadStream` above already had to abandon: the bytes cross the
// bridge as one base64 string and are decoded into one allocation on the host side, so writing a
// large file needs an allocation of the file's own size there. On Android that is a `byte[]` on a
// Java heap whose growth limit is 256 MB, and measured on a Pixel 6 importing a real library an
// 87 MB video could not be written at all: "Failed to allocate a 90894120 byte allocation with
// 51397312 free bytes and 49MB until OOM, target footprint 268435456, growth limit 268435456",
// against a file of 90,893,534 bytes, refused three times over 5 minutes 47 seconds.
//
// So it writes through `_write` and `_final`, which the shim's `Writable` prefers over its onFinish
// sink, and flushes whenever the pending bytes reach CHUNK_BYTES. The first flush writes (truncating
// anything already there, as a write stream must) and every later one appends.
//
class WriteStream extends Writable {
    //
    // The path being written.
    //
    private readonly path: string;

    //
    // Chunks written but not yet flushed to the host.
    //
    private pending: Buffer[] = [];

    //
    // How many bytes those chunks hold, so the flush decision costs no walk of the list.
    //
    private pendingBytes = 0;

    //
    // True once a flush has happened, which is what makes every later flush an append rather than a
    // second truncating write.
    //
    private hasFlushed = false;

    //
    // Builds a stream over the given sandboxed path.
    //
    constructor(path: string) {
        super();
        this.path = path;
    }

    //
    // Takes a chunk, flushing once enough have arrived. The shim's Writable calls this in preference
    // to its onFinish sink.
    //
    _write(chunk: Buffer, _encoding: string, callback: (error?: Error) => void): void {
        try {
            this.pending.push(chunk);
            this.pendingBytes += chunk.length;
            if (this.pendingBytes >= CHUNK_BYTES) {
                this.flush();
            }
            callback();
        }
        catch (error) {
            callback(error as Error);
        }
    }

    //
    // Flushes whatever is left when the stream ends.
    //
    _final(callback: (error?: Error) => void): void {
        try {
            this.flush();
            callback();
        }
        catch (error) {
            callback(error as Error);
        }
    }

    //
    // Writes the pending bytes to the host and forgets them.
    //
    // A stream that was ended with nothing written still has to produce an empty file, which is why
    // the first flush happens even with no bytes; later flushes with nothing pending do nothing.
    //
    private flush(): void {
        if (this.pendingBytes === 0 && this.hasFlushed) {
            return;
        }

        const data = this.pending.length === 1 ? this.pending[0] : Buffer.concat(this.pending);
        this.pending = [];
        this.pendingBytes = 0;

        const base64 = data.toString("base64");
        if (this.hasFlushed) {
            callHost(() => getFsHost().fsAppendFile(this.path, base64));
        }
        else {
            callHost(() => getFsHost().fsWriteFile(this.path, base64, false));
            this.hasFlushed = true;
        }
    }
}

//
// Creates a writable stream over a sandboxed path, flushing to the host in bounded chunks.
// FileStorage.writeStream pipes into this and then renames the temp file into place.
//
export function createWriteStream(path: string): Writable {
    return new WriteStream(path);
}

//
// The default export mirrors `import fs from "fs"` (only the backed members are real).
//
const fsModule = { createReadStream, createWriteStream, promises, readFileSync, statSync, lstatSync, fstatSync, ReadStream, Stats };

export default fsModule;
