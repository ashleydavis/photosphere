//
// Shared access to the native host bridge for the fs shims.
//
// The native plugin installs `globalThis.host` before any task runs, and the worker runtime
// rewrites it so missing functions throw NOT IMPLEMENTED. The fs shims read the host lazily (at call
// time, not import time) so they always see the installed/wrapped host.
//

import { Buffer } from "buffer";

//
// The subset of native host functions the fs shims call. They are synchronous native callables
// (QuickJS/JavaScriptCore call into native and return a value directly). Binary file contents
// cross the bridge as base64 strings; directory listings and stat results cross as JSON strings.
// On error a host function returns an error-envelope string (see HOST_ERROR_PREFIX) rather than
// throwing, because a thrown native exception cannot cross the QuickJS bridge safely.
//
export interface IFsHost {
    // Reads a file and returns its bytes as a base64 string, or null when the file does not exist.
    fsReadFile: (path: string) => string | null;

    // Returns true when a file or directory exists at the path.
    fsAccess: (path: string) => boolean;

    // Returns a JSON string { size, mtimeMs, isFile, isDirectory } for the path, or null when missing.
    fsStat: (path: string) => string | null;

    // Returns a JSON string array of { name, isDirectory } entries for a directory, or null when missing.
    fsReaddir: (path: string) => string | null;

    // Writes base64-decoded bytes to a path (exclusive maps the Node 'wx' flag: EEXIST if present).
    fsWriteFile: (path: string, base64: string, exclusive: boolean) => string | null;

    // Creates a directory (recursive maps Node's { recursive: true }).
    fsMkdir: (path: string, recursive: boolean) => string | null;

    // Renames/moves a file, overwriting an existing destination.
    fsRename: (srcPath: string, destPath: string) => string | null;

    // Deletes a file.
    fsUnlink: (path: string) => string | null;

    // Deletes a file or directory tree (recursive/force map the Node fs.rm options).
    fsRm: (path: string, recursive: boolean, force: boolean) => string | null;
}

//
// Returns the installed native host bridge, throwing a clear error if it is missing (which would
// indicate the fs shim was used outside the embedded worker).
//
export function getFsHost(): IFsHost {
    const host = (globalThis as any).host;
    if (!host) {
        throw new Error("Native host bridge (globalThis.host) is not installed; fs shim cannot run.");
    }

    return host as IFsHost;
}

//
// Builds an Error carrying a Node-style `code` so existing storage logic (which branches on
// `error.code === 'ENOENT'` / `'EEXIST'`) behaves identically on mobile.
//
export function codedError(code: string, message: string): NodeJS.ErrnoException {
    const error = new Error(message) as NodeJS.ErrnoException;
    error.code = code;
    return error;
}

//
// Prefix marking a host-function return value as an ERROR rather than a real result. Native host
// functions must never throw across the engine bridge (the QuickJS wrapper does not convert a thrown
// Java exception into a JS exception and would crash the process), so an error is returned as the
// string `@@HOSTERR@@<code>:<message>` and decoded here into a thrown coded Error. The '@' character
// cannot appear in a base64 result and JSON values never start with it, so a real result is never
// mistaken for an error envelope.
//
export const HOST_ERROR_PREFIX = "@@HOSTERR@@";

//
// Builds an error-envelope string. Used by the native sides (mirrored in Java/Swift) and exported so
// tests can construct one. The code precedes the first ':'; the message is the remainder.
//
export function makeHostErrorEnvelope(code: string, message: string): string {
    return HOST_ERROR_PREFIX + code + ":" + message;
}

//
// Derives a Node-style error code from a message, recognising the markers the native side embeds.
//
function codeFromMessage(message: string): string {
    if (message.includes("EEXIST")) {
        return "EEXIST";
    }
    if (message.includes("ENOENT")) {
        return "ENOENT";
    }
    return "EHOST";
}

//
// Calls a host function and normalises its outcome: if it returns an error-envelope string (the
// native error convention) or throws (defensive, e.g. iOS raising a JS exception), this throws a
// coded Error; otherwise it returns the raw result. Every fs shim routes its host call through here.
//
export function callHost<ResultT>(call: () => ResultT): ResultT {
    let result: ResultT;
    try {
        result = call();
    }
    catch (thrown) {
        const message = thrown instanceof Error ? thrown.message : String(thrown);
        throw codedError(codeFromMessage(message), message);
    }

    if (typeof result === "string" && result.startsWith(HOST_ERROR_PREFIX)) {
        const rest = result.slice(HOST_ERROR_PREFIX.length);
        const separatorIndex = rest.indexOf(":");
        const code = separatorIndex >= 0 ? rest.slice(0, separatorIndex) : "";
        const message = separatorIndex >= 0 ? rest.slice(separatorIndex + 1) : rest;
        throw codedError(code || "EHOST", message);
    }

    return result;
}

//
// Decodes a base64 string from the native bridge into a Buffer.
//
export function base64ToBuffer(base64: string): Buffer {
    return Buffer.from(base64, "base64");
}
