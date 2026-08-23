import { writeFile, mkdir, rename, unlink, rm, open } from "../../shims/node-fs-promises";
import { makeHostErrorEnvelope } from "../../shims/host-access";

//
// Unit tests for the fs/promises write functions over a capturing mock host: data marshalling
// (Buffer/string -> base64), the 'wx' exclusive flag, EEXIST mapping, mkdir recursive, and rename.
//

//
// A recorded fsWriteFile call.
//
interface IWriteCall {
    // The target path.
    path: string;

    // The base64-encoded bytes written.
    base64: string;

    // Whether the exclusive ('wx') flag was set.
    exclusive: boolean;
}

//
// Installs a capturing mock host and returns the recording arrays.
//
function installCapturingHost(throwEexistOnWrite: boolean): { writes: IWriteCall[]; mkdirs: Array<{ path: string; recursive: boolean }>; renames: Array<{ from: string; to: string }> } {
    const writes: IWriteCall[] = [];
    const mkdirs: Array<{ path: string; recursive: boolean }> = [];
    const renames: Array<{ from: string; to: string }> = [];

    (globalThis as any).host = {
        platform: "android",
        fsWriteFile: (path: string, base64: string, exclusive: boolean) => {
            if (throwEexistOnWrite) {
                throw new Error("EEXIST: file already exists: " + path);
            }
            writes.push({ path, base64, exclusive });
        },
        fsMkdir: (path: string, recursive: boolean) => {
            mkdirs.push({ path, recursive });
        },
        fsRename: (from: string, to: string) => {
            renames.push({ from, to });
        },
    };

    return { writes, mkdirs, renames };
}

describe("node-fs-promises write functions", () => {

    afterEach(() => {
        (globalThis as any).host = undefined;
    });

    test("writeFile sends base64 of a Buffer with exclusive=false", async () => {
        const captured = installCapturingHost(false);
        const data = Buffer.from([1, 2, 3, 250]);
        await writeFile("db/x.bin", data);
        expect(captured.writes).toHaveLength(1);
        expect(captured.writes[0].path).toBe("db/x.bin");
        expect(captured.writes[0].exclusive).toBe(false);
        expect(Buffer.from(captured.writes[0].base64, "base64").equals(data)).toBe(true);
    });

    test("writeFile encodes a utf8 string", async () => {
        const captured = installCapturingHost(false);
        await writeFile("db/x.txt", "héllo", "utf8");
        expect(Buffer.from(captured.writes[0].base64, "base64").toString("utf8")).toBe("héllo");
    });

    test("writeFile with flag 'wx' sets exclusive=true", async () => {
        const captured = installCapturingHost(false);
        await writeFile("db/lock", "{}", { flag: "wx" });
        expect(captured.writes[0].exclusive).toBe(true);
    });

    test("writeFile maps a thrown native EEXIST error to an EEXIST-coded error", async () => {
        installCapturingHost(true);
        await expect(writeFile("db/lock", "{}", { flag: "wx" })).rejects.toMatchObject({ code: "EEXIST" });
    });

    test("writeFile maps a returned EEXIST error envelope to an EEXIST-coded error", async () => {
        (globalThis as any).host = {
            platform: "android",
            fsWriteFile: () => makeHostErrorEnvelope("EEXIST", "file already exists: db/lock"),
        };
        await expect(writeFile("db/lock", "{}", { flag: "wx" })).rejects.toMatchObject({ code: "EEXIST" });
    });

    test("mkdir forwards the recursive flag", async () => {
        const captured = installCapturingHost(false);
        await mkdir("db/a/b", { recursive: true });
        expect(captured.mkdirs).toEqual([{ path: "db/a/b", recursive: true }]);
    });

    test("rename forwards both paths", async () => {
        const captured = installCapturingHost(false);
        await rename("db/x.tmp", "db/x");
        expect(captured.renames).toEqual([{ from: "db/x.tmp", to: "db/x" }]);
    });

    test("open with 'wx' creates the file exclusively and returns a closeable handle", async () => {
        const captured = installCapturingHost(false);
        const handle = await open("db/lock", "wx");
        expect(captured.writes).toHaveLength(1);
        expect(captured.writes[0].path).toBe("db/lock");
        expect(captured.writes[0].exclusive).toBe(true);
        expect(captured.writes[0].base64).toBe("");
        await expect(handle.close()).resolves.toBeUndefined();
    });

    test("open with 'wx' maps an existing file to an EEXIST-coded rejection", async () => {
        installCapturingHost(true);
        await expect(open("db/lock", "wx")).rejects.toMatchObject({ code: "EEXIST" });
    });

    test("open refuses any flag other than exclusive create", async () => {
        installCapturingHost(false);
        await expect(open("db/x", "r")).rejects.toThrow(/only implemented for exclusive create/);
    });

    test("unlink and rm forward to the host", async () => {
        const unlinks: string[] = [];
        const rms: Array<{ path: string; recursive: boolean; force: boolean }> = [];
        (globalThis as any).host = {
            platform: "android",
            fsUnlink: (path: string) => { unlinks.push(path); },
            fsRm: (path: string, recursive: boolean, force: boolean) => { rms.push({ path, recursive, force }); },
        };
        await unlink("db/gone");
        await rm("db/tree", { recursive: true, force: true });
        expect(unlinks).toEqual(["db/gone"]);
        expect(rms).toEqual([{ path: "db/tree", recursive: true, force: true }]);
    });
});
