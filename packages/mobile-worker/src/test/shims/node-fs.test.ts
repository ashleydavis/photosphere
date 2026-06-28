import { createReadStream, createWriteStream } from "../../shims/node-fs";
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
            fsReadFile: (path: string): string | null => files[path] ? files[path].toString("base64") : null,
            fsWriteFile: (path: string, base64: string) => { writes[path] = Buffer.from(base64, "base64"); },
        };

        await pipeline(createReadStream("db/src"), createWriteStream("db/dest"));
        expect(writes["db/dest"].toString("utf8")).toBe("copy me");
    });
});
