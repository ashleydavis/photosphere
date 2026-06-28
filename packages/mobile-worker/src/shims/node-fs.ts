//
// Mobile `fs` (sync + stream) shim.
//
// FileStorage imports `createReadStream`/`createWriteStream` from `fs`. Both are backed by the
// whole-file host bridge: createReadStream reads the whole file and emits it as one chunk;
// createWriteStream buffers written chunks and writes the whole file on end.
//

import { getFsHost, codedError, base64ToBuffer, callHost } from "./host-access";
import { Readable, Writable } from "./node-stream";

//
// Creates a readable stream over a file by reading the whole file through the host bridge and
// emitting it as a single chunk. Matches the whole-file read model used across the mobile worker.
//
export function createReadStream(path: string): Readable {
    const base64 = callHost(() => getFsHost().fsReadFile(path));
    if (base64 === null || base64 === undefined) {
        throw codedError("ENOENT", `ENOENT: no such file or directory, open '${path}'`);
    }

    return new Readable(base64ToBuffer(base64));
}

//
// Creates a writable stream that buffers chunks and, when ended, writes the whole file through the
// host bridge. Matches the whole-file write model (FileStorage.writeStream pipes into this then
// renames the temp file into place).
//
export function createWriteStream(path: string): Writable {
    return new Writable((data: Buffer) => {
        callHost(() => getFsHost().fsWriteFile(path, data.toString("base64"), false));
    });
}

//
// The default export mirrors `import fs from "fs"` (only the backed members are real).
//
const fsModule = { createReadStream, createWriteStream };

export default fsModule;
