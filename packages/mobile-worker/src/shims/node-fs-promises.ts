//
// Mobile `fs/promises` shim backing the read path on native host functions.
//
// The read path (`readFile`, `access`, `stat`, `readdir`) and the write path (`writeFile`, `open`,
// `mkdir`, `rename`, `unlink`, `rm`) are both implemented, each calling a synchronous `host.fs*`
// function and adapting the result to the Node `fs/promises` shape the storage code expects. Functions neither
// path uses (`appendFile`, `copyFile`, ...) throw the loud NOT IMPLEMENTED error rather than
// silently doing nothing, so an unaccounted-for call is obvious.
//

import { Buffer } from "buffer";
import { getFsHost, codedError, base64ToBuffer, callHost } from "./host-access";

//
// The platform string used in NOT IMPLEMENTED messages (mobile worker only ever runs on a device).
//
function hostPlatform(): string {
    const platform = (globalThis as any).host?.platform;
    return typeof platform === "string" ? platform : "mobile";
}

//
// Throws the verbatim NOT IMPLEMENTED error for an fs function the mobile read path does not need.
//
function notImplemented(name: string): never {
    throw new Error(`NOT IMPLEMENTED: native host function "${name}" is not implemented yet on ${hostPlatform()}. Implement it ASAP.`);
}

//
// Normalises Node's readFile options into an encoding string (or undefined for a Buffer result).
//
function readEncoding(options?: BufferEncoding | { encoding?: BufferEncoding | null }): string | undefined {
    if (!options) {
        return undefined;
    }

    if (typeof options === "string") {
        return options;
    }

    return options.encoding ?? undefined;
}

//
// A single directory entry returned by readdir({ withFileTypes: true }).
//
interface IRawDirEntry {
    // The entry name.
    name: string;

    // True when the entry is a directory.
    isDirectory: boolean;
}

//
// A Dirent-compatible entry exposing isFile()/isDirectory(), matching what FileStorage uses.
//
class MobileDirent {
    //
    // The entry name.
    //
    public readonly name: string;

    //
    // Whether this entry is a directory (captured from the native listing).
    //
    private readonly directory: boolean;

    //
    // Builds a Dirent from a raw native entry.
    //
    constructor(entry: IRawDirEntry) {
        this.name = entry.name;
        this.directory = entry.isDirectory;
    }

    //
    // Returns true when the entry is a regular file.
    //
    isFile(): boolean {
        return !this.directory;
    }

    //
    // Returns true when the entry is a directory.
    //
    isDirectory(): boolean {
        return this.directory;
    }
}

//
// A Stats-compatible object exposing the fields and methods FileStorage reads.
//
class MobileStats {
    //
    // File size in bytes.
    //
    public readonly size: number;

    //
    // Last-modified time.
    //
    public readonly mtime: Date;

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
// Reads a file. With a utf8/ascii encoding returns a string; otherwise returns a Buffer. Throws an
// ENOENT-coded error when the file does not exist.
//
export async function readFile(path: string, options?: BufferEncoding | { encoding?: BufferEncoding | null }): Promise<Buffer | string> {
    const base64 = callHost(() => getFsHost().fsReadFile(path));
    if (base64 === null || base64 === undefined) {
        throw codedError("ENOENT", `ENOENT: no such file or directory, open '${path}'`);
    }

    const buffer = base64ToBuffer(base64);
    const encoding = readEncoding(options);
    if (encoding) {
        return buffer.toString(encoding as BufferEncoding);
    }

    return buffer;
}

//
// Resolves when the path exists, rejects with an ENOENT-coded error otherwise. Mirrors fs.access
// used by node-utils `pathExists`.
//
export async function access(path: string): Promise<void> {
    if (!callHost(() => getFsHost().fsAccess(path))) {
        throw codedError("ENOENT", `ENOENT: no such file or directory, access '${path}'`);
    }
}

//
// Returns Stats for a path. Throws an ENOENT-coded error when the path does not exist.
//
export async function stat(path: string): Promise<MobileStats> {
    const json = callHost(() => getFsHost().fsStat(path));
    if (json === null || json === undefined) {
        throw codedError("ENOENT", `ENOENT: no such file or directory, stat '${path}'`);
    }

    const parsed = JSON.parse(json);
    return new MobileStats(parsed.size, parsed.mtimeMs, parsed.isFile, parsed.isDirectory);
}

//
// Lists a directory. With { withFileTypes: true } returns Dirent objects; otherwise returns names.
// Throws an ENOENT-coded error when the directory does not exist.
//
export async function readdir(path: string, options?: { withFileTypes?: boolean }): Promise<string[] | MobileDirent[]> {
    const json = callHost(() => getFsHost().fsReaddir(path));
    if (json === null || json === undefined) {
        throw codedError("ENOENT", `ENOENT: no such file or directory, scandir '${path}'`);
    }

    const entries = JSON.parse(json) as IRawDirEntry[];
    if (options?.withFileTypes) {
        return entries.map(entry => new MobileDirent(entry));
    }

    return entries.map(entry => entry.name);
}

//
// Options accepted by writeFile: an encoding string, or an object with encoding and/or a flag.
//
interface IWriteFileOptions {
    // Text encoding when data is a string.
    encoding?: BufferEncoding | null;

    // File-system flag; only 'wx'/'wx+' (exclusive create) is interpreted specially.
    flag?: string;
}

//
// Writes data (Buffer or string) to a file. The 'wx' flag requests exclusive create: if the file
// already exists the native side throws an EEXIST-marked error, which is re-thrown with code
// 'EEXIST' so the storage write-lock logic behaves as on desktop.
//
export async function writeFile(path: string, data: Buffer | Uint8Array | string, options?: BufferEncoding | IWriteFileOptions): Promise<void> {
    const encoding = typeof options === "string" ? options : (options?.encoding ?? undefined);
    const flag = typeof options === "string" ? undefined : options?.flag;
    const exclusive = flag === "wx" || flag === "wx+";

    const buffer = typeof data === "string"
        ? Buffer.from(data, (encoding as BufferEncoding) || "utf8")
        : Buffer.from(data);

    callHost(() => getFsHost().fsWriteFile(path, buffer.toString("base64"), exclusive));
}

//
// The handle returned by `open`. Only `close` is offered, because the only caller opens a lock file
// to find out whether it could be created and closes it immediately.
//
export interface IMobileFileHandle {
    // Releases the handle. Nothing is held open on the native side, so this has nothing to release.
    close(): Promise<void>;
}

//
// Opens a file for exclusive create ('wx'/'wx+') and returns a handle.
//
// What this fixes: the hash cache never persisted a single entry on Android or iOS, so every
// automatic import re-exported and re-hashed every photo it had already imported, on every run.
//
// Why it was needed: `updateFileRawOptimistic` in node-utils takes its exclusive lock by calling
// `fs.open(lockPath, 'wx')`, and this shim exported no `open` at all, so inside the embedded engine
// that call was `undefined` and threw a TypeError. The throw travelled up into `HashCache.save()`,
// whose catch swallowed it, leaving the cache directory permanently empty and nothing said.
//
// How it targets the problem: it supplies exactly the one call that was missing, routed through the
// `writeFile` above so it lands on the native `fsWriteFile` path that already exists and already
// maps the native EEXIST error to an EEXIST-coded one, which is what tells the lock "somebody else
// holds it" apart from a real fault. Every other flag is refused by name rather than handed back a
// handle that cannot read or write, so this cannot quietly become a general-purpose `open` later.
//
export async function open(path: string, flags: string): Promise<IMobileFileHandle> {
    if (flags !== "wx" && flags !== "wx+") {
        throw new Error(`fs.open is only implemented for exclusive create ('wx'/'wx+') on ${hostPlatform()}, not for flags '${flags}'.`);
    }

    await writeFile(path, Buffer.alloc(0), { flag: "wx" });

    return {
        close: async (): Promise<void> => {
            // Nothing is held open on the native side, so there is nothing to release.
        },
    };
}

//
// Creates a directory. Only the recursive form is used by the storage layer.
//
export async function mkdir(path: string, options?: { recursive?: boolean }): Promise<void> {
    callHost(() => getFsHost().fsMkdir(path, options?.recursive === true));
}

//
// Renames/moves a file, overwriting an existing destination (Node semantics).
//
export async function rename(oldPath: string, newPath: string): Promise<void> {
    callHost(() => getFsHost().fsRename(oldPath, newPath));
}

//
// Deletes a file. Throws an ENOENT-coded error when missing (callers that tolerate that catch it).
//
export async function unlink(path: string): Promise<void> {
    callHost(() => getFsHost().fsUnlink(path));
}

//
// Removes a file or directory tree. With { force: true } a missing path is ignored.
//
export async function rm(path: string, options?: { recursive?: boolean; force?: boolean }): Promise<void> {
    callHost(() => getFsHost().fsRm(path, options?.recursive === true, options?.force === true));
}

//
// Not needed by the implemented paths yet.
//
export async function appendFile(): Promise<void> {
    notImplemented("fsAppendFile");
}

//
// Copies a file natively, so its bytes never cross the bridge.
//
// This is what storage uses to put an imported photo into the database. Going through the stream
// shims instead would read the whole photo into the engine as a base64 string and write it back out
// as another one, which for a five megabyte photo is two seven megabyte strings built inside the JS
// engine to accomplish a copy the platform can do without moving anything into the engine at all.
//
export async function copyFile(srcPath: string, destPath: string): Promise<void> {
    callHost(() => getFsHost().fsCopyFile(srcPath, destPath));
}

//
// The default export mirrors `import fsPromises from "fs/promises"`.
//
const fsPromises = { readFile, access, stat, readdir, writeFile, open, mkdir, rename, unlink, rm, appendFile, copyFile };

export default fsPromises;
