//
// Minimal POSIX `path` shim for the embedded mobile worker.
//
// The embedded QuickJS/JavaScriptCore engine has no Node `path` module. The storage code
// (`packages/storage`, `packages/node-utils`) imports `path`/`node:path` for `join`, `dirname`,
// `resolve`, `basename`, and `extname`. This shim provides those using forward-slash POSIX
// semantics, which match the storage layer (it always works in `/`-separated paths).
//
// One deliberate deviation from Node: `resolve` does NOT force an absolute path. On mobile every
// storage path is relative to the native sandbox root (the app's private files directory), and the
// native `PathSandbox` rejects absolute paths. Returning a sandbox-relative path here keeps
// `createStorage` (which calls `path.resolve(rootPath)`) producing paths the host fs functions can
// resolve under the sandbox root.
//

//
// The POSIX path separator. The storage layer only ever uses forward slashes.
//
export const sep = "/";

//
// Splits a path into its non-empty segments, remembering whether it began absolute.
//
function splitSegments(inputPath: string): string[] {
    return inputPath.split("/").filter(segment => segment.length > 0);
}

//
// Collapses `.` and `..` segments in a list of path segments, preserving leading `..` for
// relative paths so traversal is represented faithfully.
//
function collapseSegments(segments: string[], isAbsolute: boolean): string[] {
    const result: string[] = [];
    for (const segment of segments) {
        if (segment === ".") {
            continue;
        }

        if (segment === "..") {
            if (result.length > 0 && result[result.length - 1] !== "..") {
                result.pop();
            }
            else if (!isAbsolute) {
                result.push("..");
            }
            continue;
        }

        result.push(segment);
    }

    return result;
}

//
// Normalises a path: collapses redundant separators and `.`/`..` segments. Preserves a leading
// slash for absolute inputs and returns "." for an empty relative result.
//
export function normalize(inputPath: string): string {
    const isAbsolute = inputPath.startsWith("/");
    const collapsed = collapseSegments(splitSegments(inputPath), isAbsolute);
    const joined = collapsed.join("/");

    if (isAbsolute) {
        return "/" + joined;
    }

    return joined.length > 0 ? joined : ".";
}

//
// Joins path segments with the POSIX separator, then normalises the result.
//
export function join(...parts: string[]): string {
    const nonEmpty = parts.filter(part => part.length > 0);
    if (nonEmpty.length === 0) {
        return ".";
    }

    return normalize(nonEmpty.join("/"));
}

//
// Resolves a sequence of paths into a single normalised path. Unlike Node, the result is NOT
// forced absolute: a relative input stays relative so it can be resolved under the native sandbox
// root. An absolute input (one starting with `/`) is preserved as absolute.
//
export function resolve(...parts: string[]): string {
    let resolved = "";
    for (const part of parts) {
        if (part.length === 0) {
            continue;
        }

        if (part.startsWith("/")) {
            // An absolute segment resets the accumulated path, matching Node's resolve semantics.
            resolved = part;
        }
        else {
            resolved = resolved.length > 0 ? resolved + "/" + part : part;
        }
    }

    return normalize(resolved.length > 0 ? resolved : ".");
}

//
// Returns the directory portion of a path (everything before the final separator).
//
export function dirname(inputPath: string): string {
    const normalised = normalize(inputPath);
    const lastSlash = normalised.lastIndexOf("/");
    if (lastSlash === -1) {
        return ".";
    }

    if (lastSlash === 0) {
        return "/";
    }

    return normalised.slice(0, lastSlash);
}

//
// Returns the final portion of a path, optionally stripping a trailing extension suffix.
//
export function basename(inputPath: string, suffix?: string): string {
    const segments = splitSegments(inputPath);
    let base = segments.length > 0 ? segments[segments.length - 1] : "";
    if (suffix && base.endsWith(suffix) && base !== suffix) {
        base = base.slice(0, base.length - suffix.length);
    }

    return base;
}

//
// Returns the file extension of a path (including the leading dot), or an empty string when none.
//
export function extname(inputPath: string): string {
    const base = basename(inputPath);
    const dotIndex = base.lastIndexOf(".");
    if (dotIndex <= 0) {
        return "";
    }

    return base.slice(dotIndex);
}

//
// The default export mirrors Node's `path` default export so `import path from "node:path"` works.
//
const posixPath = { sep, normalize, join, resolve, dirname, basename, extname };

export default posixPath;
