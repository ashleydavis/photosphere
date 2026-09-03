import { createReadStream, createWriteStream, fstatSync, lstatSync, promises, readFileSync, ReadStream, statSync } from "../../shims/node-fs";
import { pipeline } from "../../shims/node-stream-promises";

//
// Unit tests for the fs (sync/stream) shim over a mock native host.
//
describe("node-fs shim", () => {

    beforeEach(() => {
        const files: Record<string, Buffer> = {
            "db/file": Buffer.from("file contents", "utf8"),
        };
        (globalThis as any).host = {
            platform: "android",
            fsAccess: (path: string): boolean => {
                return path in files;
            },
            fsReadFile: (path: string): string | null => {
                return files[path] ? files[path].toString("base64") : null;
            },
            // The real host has both of these, and a read stream needs them: it walks a file a chunk
            // at a time rather than asking for all of it at once.
            fsReadFileRange: (path: string, start: number, length: number): string | null => {
                const file = files[path];
                if (!file) {
                    return null;
                }
                return file.subarray(start, start + length).toString("base64");
            },
            fsStat: (path: string): string | null => {
                const file = files[path];
                if (!file) {
                    return null;
                }
                return JSON.stringify({
                    size: file.length,
                    mtimeMs: 0,
                    isFile: true,
                    isDirectory: false,
                });
            },
        };
    });

    afterEach(() => {
        (globalThis as any).host = undefined;
    });

    test("createReadStream emits the whole file as one chunk", async () => {
        const stream = createReadStream("db/file");
        const chunk = await new Promise<Buffer>((resolveData, rejectData) => {
            stream.on("data", (data: Buffer) => resolveData(data));
            stream.on("error", (error: Error) => rejectData(error));
        });
        expect(chunk.toString("utf8")).toBe("file contents");
    });

    test("createReadStream throws ENOENT for a missing file", () => {
        expect(() => createReadStream("db/missing")).toThrow(
            expect.objectContaining({ code: "ENOENT" })
        );
    });

    test("createWriteStream writes the buffered bytes through the host on end", async () => {
        const writes: Array<{ path: string; base64: string }> = [];
        (globalThis as any).host = {
            platform: "android",
            fsWriteFile: (path: string, base64: string) => { writes.push({ path, base64 }); },
        };

        const writable = createWriteStream("db/out");
        writable.write(Buffer.from("hello "));
        writable.end(Buffer.from("world"));

        expect(writes).toHaveLength(1);
        expect(writes[0].path).toBe("db/out");
        expect(Buffer.from(writes[0].base64, "base64").toString("utf8")).toBe("hello world");
    });

    test("pipeline from createReadStream to createWriteStream copies the bytes", async () => {
        const files: Record<string, Buffer> = { "db/src": Buffer.from("copy me", "utf8") };
        const writes: Record<string, Buffer> = {};
        (globalThis as any).host = {
            platform: "android",
            fsAccess: (path: string): boolean => {
                return path in files;
            },
            fsReadFileRange: (path: string, start: number, length: number): string | null =>
                files[path] ? files[path].subarray(start, start + length).toString("base64") : null,
            fsStat: (path: string): string | null => files[path]
                ? JSON.stringify({ size: files[path].length, mtimeMs: 0, isFile: true, isDirectory: false })
                : null,
            fsWriteFile: (path: string, base64: string) => { writes[path] = Buffer.from(base64, "base64"); },
        };

        await pipeline(createReadStream("db/src"), createWriteStream("db/dest"));
        expect(writes["db/dest"].toString("utf8")).toBe("copy me");
    });

    test("a file larger than one chunk crosses the bridge in pieces rather than all at once", async () => {
        // A whole file used to come back in a single call, and base64 is a third bigger again than
        // the bytes it carries. That is survivable for a photo and fatal for a video: syncing a real
        // library from a Pixel 6 died on a 100MB video with "Failed to allocate a 105478648 byte
        // allocation ... growth limit 268435456", and every pass after it died the same way on the
        // same file, so nothing beyond that video ever reached the origin.
        const contents = Buffer.alloc(10 * 1024 * 1024, 7);
        const files: Record<string, Buffer> = { "db/big": contents };
        const requestedLengths: number[] = [];
        (globalThis as any).host = {
            platform: "android",
            fsAccess: (path: string): boolean => {
                return path in files;
            },
            fsReadFile: (): string | null => {
                throw new Error("a whole file must never be fetched in one call");
            },
            fsReadFileRange: (path: string, start: number, length: number): string | null => {
                requestedLengths.push(length);
                return files[path].subarray(start, start + length).toString("base64");
            },
            fsStat: (path: string): string | null => JSON.stringify({
                size: files[path].length,
                mtimeMs: 0,
                isFile: true,
                isDirectory: false,
            }),
        };

        const chunks: Buffer[] = [];
        const stream = createReadStream("db/big");
        await new Promise<void>((resolve, reject) => {
            stream.on("data", (chunk: Buffer) => chunks.push(chunk));
            stream.on("end", () => resolve());
            stream.on("error", reject);
        });

        expect(Buffer.concat(chunks).length).toBe(contents.length);
        expect(Buffer.concat(chunks).equals(contents)).toBe(true);
        expect(requestedLengths.length).toBeGreaterThan(1);
        expect(Math.max(...requestedLengths)).toBeLessThanOrEqual(4 * 1024 * 1024);
    });

    test("a file piped into a request is handed over rather than read", async () => {
        // An upload is a file piped into an HTTP request, and the request can have the bytes sent
        // from disk to the socket natively. Read here instead, they cross the host bridge as base64,
        // a third larger than the bytes they carry and decoded in an interpreter, and then cross it
        // again on the way out: measured on a Pixel 6 that was about three megabytes a minute, with
        // the network idle nine tenths of the time.
        const files: Record<string, Buffer> = { "db/photo": Buffer.alloc(3 * 1024 * 1024, 4) };
        let readCount = 0;
        (globalThis as any).host = {
            platform: "android",
            fsAccess: (path: string): boolean => path in files,
            fsReadFileRange: (path: string, start: number, length: number): string | null => {
                readCount += 1;
                return files[path].subarray(start, start + length).toString("base64");
            },
            fsStat: (path: string): string | null => JSON.stringify({
                size: files[path].length,
                mtimeMs: 0,
                isFile: true,
                isDirectory: false,
            }),
        };

        const handedOver: Array<{ path: string, offset: number, length: number }> = [];
        const destination = {
            writeFileBody: (path: string, offset: number, length: number): boolean => {
                handedOver.push({ path, offset, length });
                return true;
            },
            write: (): boolean => {
                throw new Error("the bytes must not be written in one at a time");
            },
            end: (): void => {},
        };

        createReadStream("db/photo").pipe(destination as any);

        expect(handedOver).toEqual([{ path: "db/photo", offset: 0, length: 3 * 1024 * 1024 }]);
        expect(readCount).toBe(0);
    });

    test("a file is read the ordinary way when the destination cannot take one", async () => {
        const files: Record<string, Buffer> = { "db/photo": Buffer.from("some-bytes", "utf8") };
        (globalThis as any).host = {
            platform: "android",
            fsAccess: (path: string): boolean => path in files,
            fsReadFileRange: (path: string, start: number, length: number): string | null =>
                files[path].subarray(start, start + length).toString("base64"),
            fsStat: (path: string): string | null => JSON.stringify({
                size: files[path].length,
                mtimeMs: 0,
                isFile: true,
                isDirectory: false,
            }),
        };

        const written: Buffer[] = [];
        const destination = {
            write: (chunk: Buffer): boolean => {
                written.push(chunk);
                return true;
            },
            end: (): void => {},
        };

        createReadStream("db/photo").pipe(destination as any);
        await new Promise(resolve => setTimeout(resolve, 50));

        expect(Buffer.concat(written).toString("utf8")).toBe("some-bytes");
    });

    test("createReadStream returns a ReadStream carrying the path it was opened from", () => {
        const stream = createReadStream("db/file");

        expect(stream).toBeInstanceOf(ReadStream);
        expect(stream.path).toBe("db/file");
    });

    test("createReadStream does not read the file until something consumes the stream", async () => {
        // The point of it. Storage recognises a file-backed stream by its path and copies the file
        // natively rather than piping it, so for every photo taken into a database the eager read
        // fetched the whole file across the bridge as a base64 string and then threw it away unread.
        let readCount = 0;
        const files: Record<string, Buffer> = { "db/file": Buffer.from("file contents", "utf8") };
        (globalThis as any).host = {
            platform: "android",
            fsAccess: (path: string): boolean => {
                return path in files;
            },
            fsReadFileRange: (path: string, start: number, length: number): string | null => {
                readCount += 1;
                return files[path] ? files[path].subarray(start, start + length).toString("base64") : null;
            },
            fsStat: (path: string): string | null => {
                if (!files[path]) {
                    return null;
                }
                return JSON.stringify({
                    size: files[path].length,
                    mtimeMs: 0,
                    isFile: true,
                    isDirectory: false,
                });
            },
        };

        const stream = createReadStream("db/file");
        expect(stream.path).toBe("db/file");
        expect(readCount).toBe(0);

        const chunks: Buffer[] = [];
        await new Promise<void>((resolve, reject) => {
            stream.on("data", (chunk: Buffer) => chunks.push(chunk));
            stream.on("end", () => resolve());
            stream.on("error", reject);
        });

        expect(readCount).toBe(1);
        expect(Buffer.concat(chunks).toString("utf8")).toBe("file contents");
    });

    test("createReadStream reads only the range asked for, through the ranged host call", async () => {
        // Reading a photo's EXIF needs its first few kilobytes, and the whole photo crossing the
        // bridge to get at them was 689 milliseconds per photo on a Pixel 6.
        const ranges: Array<{ path: string; offset: number; length: number }> = [];
        const files: Record<string, Buffer> = { "db/file": Buffer.from("0123456789", "utf8") };
        (globalThis as any).host = {
            platform: "android",
            fsAccess: (path: string): boolean => {
                return path in files;
            },
            fsReadFile: (): string | null => {
                throw new Error("the whole file must not be read when a range was asked for");
            },
            fsReadFileRange: (path: string, offset: number, length: number): string | null => {
                ranges.push({ path, offset, length });
                return files[path].subarray(offset, offset + length).toString("base64");
            },
        };

        const stream = createReadStream("db/file", { start: 0, end: 3 });
        const chunks: Buffer[] = [];
        await new Promise<void>((resolve, reject) => {
            stream.on("data", (chunk: Buffer) => chunks.push(chunk));
            stream.on("end", () => resolve());
            stream.on("error", reject);
        });

        expect(ranges).toEqual([{ path: "db/file", offset: 0, length: 4 }]);
        expect(Buffer.concat(chunks).toString("utf8")).toBe("0123");
    });

    test("readFileSync returns the raw bytes, or a string when an encoding is given", () => {
        expect((readFileSync("db/file") as Buffer).toString("utf8")).toBe("file contents");
        expect(readFileSync("db/file", "utf8")).toBe("file contents");
    });

    test("readFileSync throws ENOENT for a missing file", () => {
        expect(() => readFileSync("db/missing")).toThrow(
            expect.objectContaining({ code: "ENOENT" })
        );
    });

    test("statSync reports the size and kind the native stat returned", () => {
        (globalThis as any).host = {
            platform: "android",
            fsStat: (path: string): string | null => path === "db/file"
                ? JSON.stringify({ size: 13, mtimeMs: 1000, isFile: true, isDirectory: false })
                : null,
        };

        const stats = statSync("db/file");

        expect(stats.size).toBe(13);
        expect(stats.isFile()).toBe(true);
        expect(stats.isDirectory()).toBe(false);
        expect(stats.mtime.getTime()).toBe(1000);
    });

    test("statSync throws ENOENT for a missing path", () => {
        (globalThis as any).host = { platform: "android", fsStat: (): string | null => null };

        expect(() => statSync("db/missing")).toThrow(
            expect.objectContaining({ code: "ENOENT" })
        );
    });

    test("lstatSync matches statSync, since the host bridge does not distinguish symlinks", () => {
        (globalThis as any).host = {
            platform: "android",
            fsStat: (): string => JSON.stringify({ size: 7, mtimeMs: 2000, isFile: true, isDirectory: false }),
        };

        expect(lstatSync("db/file").size).toBe(statSync("db/file").size);
    });

    test("fstatSync refuses by name, because the host bridge issues no file descriptors", () => {
        expect(() => fstatSync(3)).toThrow(/NOT IMPLEMENTED/);
    });

    test("promises exposes the same implementation as the fs/promises shim", () => {
        expect(typeof promises.readFile).toBe("function");
        expect(typeof promises.stat).toBe("function");
    });
});
