import { createHash } from "node:crypto";
import { type Readable } from "node:stream";

//
// Computes a hash from a stream.
//
export function computeHash(inputStream: Readable): Promise<Buffer> {
    return new Promise<Buffer>((resolve, reject) => {
        const hash = createHash("sha256");

        inputStream.on("data", (chunk: Buffer) => {
            hash.update(chunk);
        });

        inputStream.on("end", () => {
            resolve(hash.digest());
        });

        inputStream.on("error", (error) => {
            reject(error);
        });
    });
}
