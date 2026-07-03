//
// The native platform the embedded worker is running on. Used so the
// NOT IMPLEMENTED error message can name the platform that is missing the
// native implementation.
//
export type HostPlatform = "ios" | "android";

//
// A native host function exposed on the host bridge. Different host functions
// have different signatures, so the generic machinery treats them as a
// permissive callable.
//
export type HostFunction = (...args: any[]) => any;

//
// The native host bridge. The native plugin installs this as `globalThis.host`
// before calling `runTask`. Its members are native callables (Swift on iOS,
// Kotlin/Java on Android) plus the plugin-owned session id.
//
export interface IHost {
    // Identifies the native platform so NOT IMPLEMENTED errors can name it.
    platform: HostPlatform;

    // The session id owned by the native plugin, shared by every engine and task in the pool.
    sessionId: string;

    // Streams a message (already JSON-encoded) from a running task back to native.
    sendMessage: (taskId: string, messageJson: string) => void;

    // Returns true if the task with this id has been cancelled and should stop as soon as possible.
    isCancelled: (taskId: string) => boolean;

    // Hashes the file at the given storage path natively. First-slice demonstrator (real native impl lands later).
    sha256: (path: string) => string;

    // Reads a sandboxed file, returning its bytes as base64 (or null when the file is missing).
    fsReadFile: (path: string) => string | null;

    // Returns whether a sandboxed file or directory exists.
    fsAccess: (path: string) => boolean;

    // Returns a JSON stat string { size, mtimeMs, isFile, isDirectory } for a sandboxed path (or null when missing).
    fsStat: (path: string) => string | null;

    // Returns a JSON listing of { name, isDirectory } entries for a sandboxed directory (or null when missing).
    fsReaddir: (path: string) => string | null;

    // Writes base64-decoded bytes to a sandboxed path (exclusive maps the Node 'wx' flag).
    fsWriteFile: (path: string, base64: string, exclusive: boolean) => void;

    // Creates a sandboxed directory (recursive maps Node's { recursive: true }).
    fsMkdir: (path: string, recursive: boolean) => void;

    // Renames/moves a sandboxed file, overwriting an existing destination.
    fsRename: (srcPath: string, destPath: string) => void;

    // Deletes a sandboxed file.
    fsUnlink: (path: string) => void;

    // Deletes a sandboxed file or directory tree.
    fsRm: (path: string, recursive: boolean, force: boolean) => void;

    // Binds a loopback TCP listener and returns a JSON string { listenerId, port } (port resolved when 0 was requested).
    tcpListen: (host: string, port: number) => string;

    // Writes base64-encoded bytes to an accepted connection.
    tcpWrite: (connectionId: string, base64: string) => string | null;

    // Closes one accepted connection.
    tcpClose: (connectionId: string) => string | null;

    // Closes a TCP listener so it accepts no further connections.
    tcpStopListening: (listenerId: string) => string | null;

    // Runs an in-process ImageMagick argv (JSON-encoded string[]); returns a JSON string { exitCode, output }.
    imageMagick: (argvJson: string) => string;

    // Runs an in-process ffmpeg argv (JSON-encoded string[]); returns a JSON string { exitCode, output }.
    ffmpeg: (argvJson: string) => string;

    // Runs an in-process ffprobe argv (JSON-encoded string[]); returns a JSON string { exitCode, output }.
    ffprobe: (argvJson: string) => string;
}

//
// The host functions the bundle expects the native side to install. Any name in
// this list that native did not install gets a function that throws the
// NOT IMPLEMENTED error, so a missing native function fails loudly instead of
// surfacing as `undefined`. This list is the single place to extend as later
// steps add more host functions (the `fs.*` and media functions).
//
export const EXPECTED_HOST_FUNCTIONS: string[] = [
    "sendMessage",
    "isCancelled",
    "sha256",
    "fsReadFile",
    "fsAccess",
    "fsStat",
    "fsReaddir",
    "fsWriteFile",
    "fsMkdir",
    "fsRename",
    "fsUnlink",
    "fsRm",
    "tcpListen",
    "tcpWrite",
    "tcpClose",
    "tcpStopListening",
    "imageMagick",
    "ffmpeg",
    "ffprobe",
];

//
// Builds the exact NOT IMPLEMENTED error message used verbatim on both platforms.
//
export function notImplementedMessage(name: string, platform: HostPlatform): string {
    return `NOT IMPLEMENTED: native host function "${name}" is not implemented yet on ${platform}. Implement it ASAP.`;
}

//
// Resolves a single expected host function: returns the native function bound to
// the host if it was installed, otherwise a function that throws the NOT IMPLEMENTED
// error when called (for a native function the platform has not implemented yet).
//
function resolveHostFunction(rawHost: IHost, name: string, platform: HostPlatform): HostFunction {
    const candidate = (rawHost as any)[name];
    if (typeof candidate === "function") {
        return candidate.bind(rawHost);
    }

    return function notImplementedHostFunction(): never {
        throw new Error(notImplementedMessage(name, platform));
    };
}

//
// Builds the effective host object from the raw native-installed host. Every
// expected host function is set to either the native function or a function
// that throws the NOT IMPLEMENTED error, so any host method native did not
// install fails loudly the moment it is called.
//
export function buildHost(rawHost: IHost): IHost {
    const platform = rawHost.platform;
    const effectiveHost = { ...rawHost } as IHost;
    for (const name of EXPECTED_HOST_FUNCTIONS) {
        (effectiveHost as any)[name] = resolveHostFunction(rawHost, name, platform);
    }

    return effectiveHost;
}
