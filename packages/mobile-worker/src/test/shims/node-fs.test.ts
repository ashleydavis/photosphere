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
            fsReadFile: (path: string): string | null => files[path] ? files[path].toString("base64") : null,
            fsWriteFile: (path: string, base64: string) => { writes[path] = Buffer.from(base64, "base64"); },
        };

        await pipeline(createReadStream("db/src"), createWriteStream("db/dest"));
        expect(writes["db/dest"].toString("utf8")).toBe("copy me");
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
            fsReadFile: (path: string): string | null => {
                readCount += 1;
                return files[path] ? files[path].toString("base64") : null;
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
