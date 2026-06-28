//
// `zlib` shim for the embedded mobile worker, backed by pako (pure JS).
//
// `packages/serialization` gzip-compresses serialized payloads, and the merkle-tree reader
// (`CompressedBinaryDeserializer`) gunzips them on load. Opening a database reads `.db/files.dat`
// through that reader, so `gunzipSync` is genuinely on the read path and must work. pako provides a
// pure-JS gzip/gunzip that runs in the engine without native zlib.
//

import { Buffer } from "buffer";
import pako from "pako";

//
// Options accepted by gzipSync (only the compression level is honoured).
//
interface IGzipOptions {
    // zlib compression level (0-9).
    level?: number;
}

//
// Gzip-compresses a buffer, returning a Buffer (matching Node's zlib.gzipSync).
//
export function gzipSync(buffer: Buffer | Uint8Array, options?: IGzipOptions): Buffer {
    const compressed = options?.level !== undefined
        ? pako.gzip(buffer, { level: options.level })
        : pako.gzip(buffer);
    return Buffer.from(compressed);
}

//
// Gunzips a buffer, returning a Buffer (matching Node's zlib.gunzipSync).
//
export function gunzipSync(buffer: Buffer | Uint8Array): Buffer {
    const decompressed = pako.ungzip(buffer);
    return Buffer.from(decompressed);
}

//
// The default export mirrors `import zlib from "zlib"`.
//
const zlibModule = { gzipSync, gunzipSync };

export default zlibModule;
