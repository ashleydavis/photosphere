//
// Shared access to the native media tool host functions (ImageMagick / ffmpeg / ffprobe).
//
// The mobile `Image`/`Video` tools build argv with the pure `media-commands` builders and run them
// through the native host bridge. Each media host function takes a JSON-encoded argv string and
// returns a JSON string `{ exitCode, output }`; an error is returned as the `@@HOSTERR@@` envelope
// (never thrown across the engine bridge) and decoded into a coded Error by `callHost`. The host is
// read lazily at call time (mirroring the fs shims) so the runtime-wrapped host is always seen.
//

import { callHost } from "./host-access";

//
// The decoded result of running one media tool invocation.
//
export interface IMediaResult {
    // Native exit code; 0 == success.
    exitCode: number;

    // Captured stdout (e.g. ffprobe JSON, identify text); empty for pure file-producing operations.
    output: string;
}

//
// The subset of native host functions the mobile media tools call. Each takes a JSON-encoded argv
// string and returns a JSON string `{ exitCode, output }` (or an `@@HOSTERR@@` envelope on failure).
//
export interface IMediaHost {
    // Runs an ImageMagick argv (the native side prepends "magick").
    imageMagick: (argvJson: string) => string;

    // Runs an ffmpeg argv.
    ffmpeg: (argvJson: string) => string;

    // Runs an ffprobe argv.
    ffprobe: (argvJson: string) => string;
}

//
// Returns the installed native host bridge (read lazily at call time), throwing a clear error if it
// is missing (which would indicate a media tool was used outside the embedded worker).
//
export function getMediaHost(): IMediaHost {
    const host = (globalThis as any).host;
    if (!host) {
        throw new Error("Native host bridge (globalThis.host) is not installed; media tool cannot run.");
    }

    return host as IMediaHost;
}

//
// Runs a media tool host function with the given argv. JSON-encodes the argv, invokes the host
// function through `callHost` (so an `@@HOSTERR@@` envelope throws a coded Error), and JSON-parses
// the `{ exitCode, output }` result. A non-zero exit is returned (not thrown); callers decide how to
// treat it. The host function itself is passed in (one of host.imageMagick/ffmpeg/ffprobe) so this
// helper stays agnostic about which tool runs.
//
export function runMediaTool(hostFunction: (argvJson: string) => string, argv: string[]): IMediaResult {
    const argvJson = JSON.stringify(argv);
    const resultJson = callHost(() => hostFunction(argvJson));
    const parsed = JSON.parse(resultJson) as IMediaResult;
    return parsed;
}
