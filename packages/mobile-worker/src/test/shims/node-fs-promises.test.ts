import { readFile, access, stat, readdir, appendFile, copyFile } from "../../shims/node-fs-promises";

//
// Unit tests for the fs/promises shim over a mock native host. Read functions are backed; every
// write-path function must throw the loud NOT IMPLEMENTED error.
//

//
// Builds a mock globalThis.host backed by in-memory files and directories.
//
function installMockHost(): void {
    const files: Record<string, Buffer> = {
        "db/a.txt": Buffer.from("hello world", "utf8"),
        "db/bin": Buffer.from([0, 1, 2, 250, 255]),
    };
    const dirs: Record<string, Array<{ name: string; isDirectory: boolean }>> = {
        "db": [
            { name: "a.txt", isDirectory: false },
            { name: "bin", isDirectory: false },
            { name: "sub", isDirectory: true },
        ],
    };

    (globalThis as any).host = {
        platform: "android",
        fsReadFile: (path: string): string | null => {
            return files[path] ? files[path].toString("base64") : null;
        },
        fsAccess: (path: string): boolean => {
            return path in files || path in dirs;
        },
        fsStat: (path: string): string | null => {
            if (files[path]) {
                return JSON.stringify({ size: files[path].length, mtimeMs: 1700000000000, isFile: true, isDirectory: false });
            }
            if (dirs[path]) {
                return JSON.stringify({ size: 0, mtimeMs: 1700000000000, isFile: false, isDirectory: true });
            }
            return null;
        },
        fsReaddir: (path: string): string | null => {
            return dirs[path] ? JSON.stringify(dirs[path]) : null;
        },
    };
}

describe("node-fs-promises shim", () => {

    beforeEach(() => {
        installMockHost();
    });

    afterEach(() => {
        (globalThis as any).host = undefined;
    });

    test("readFile returns a Buffer with no encoding", async () => {
        const result = await readFile("db/bin");
        expect(Buffer.isBuffer(result)).toBe(true);
        expect((result as Buffer).equals(Buffer.from([0, 1, 2, 250, 255]))).toBe(true);
    });

    test("readFile returns a string with utf8 encoding", async () => {
        expect(await readFile("db/a.txt", "utf8")).toBe("hello world");
        expect(await readFile("db/a.txt", { encoding: "utf8" })).toBe("hello world");
    });

    test("readFile throws ENOENT for a missing file", async () => {
        await expect(readFile("db/missing")).rejects.toMatchObject({ code: "ENOENT" });
    });

    test("access resolves when present and rejects ENOENT when missing", async () => {
        await expect(access("db/a.txt")).resolves.toBeUndefined();
        await expect(access("db/missing")).rejects.toMatchObject({ code: "ENOENT" });
    });

    test("stat returns size, mtime and type predicates", async () => {
        const fileStat = await stat("db/a.txt");
        expect(fileStat.size).toBe(11);
        expect(fileStat.isFile()).toBe(true);
        expect(fileStat.isDirectory()).toBe(false);
        expect(fileStat.mtime instanceof Date).toBe(true);

        const dirStat = await stat("db");
        expect(dirStat.isDirectory()).toBe(true);
        expect(dirStat.isFile()).toBe(false);
    });

    test("stat throws ENOENT for a missing path", async () => {
        await expect(stat("db/missing")).rejects.toMatchObject({ code: "ENOENT" });
    });

    test("readdir returns names by default", async () => {
        expect(await readdir("db")).toEqual(["a.txt", "bin", "sub"]);
    });

    test("readdir returns Dirent objects with withFileTypes", async () => {
        const entries = await readdir("db", { withFileTypes: true });
        const sub = (entries as any[]).find(entry => entry.name === "sub");
        const file = (entries as any[]).find(entry => entry.name === "a.txt");
        expect(sub.isDirectory()).toBe(true);
        expect(sub.isFile()).toBe(false);
        expect(file.isFile()).toBe(true);
        expect(file.isDirectory()).toBe(false);
    });

    test("readdir throws ENOENT for a missing directory", async () => {
        await expect(readdir("nope")).rejects.toMatchObject({ code: "ENOENT" });
    });

    test("the unimplemented entry points fail loudly rather than silently doing nothing", async () => {
        // These are not on any implemented mobile path; a call must surface, not no-op.
        await expect(appendFile()).rejects.toThrow(/NOT IMPLEMENTED.*fsAppendFile/);
        await expect(copyFile()).rejects.toThrow(/NOT IMPLEMENTED.*fsCopyFile/);
    });

});
