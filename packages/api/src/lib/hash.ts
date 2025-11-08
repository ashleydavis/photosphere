import { createHash } from "node:crypto";
import { IFileStat } from "./file-scanner";
import fs from "fs-extra";
import { IHashedData } from "merkle-tree";

//
// Computes a hash from a stream.
//
export function computeHash(inputStream: NodeJS.ReadableStream): Promise<Buffer> {
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

//
// Computes the hash of an asset storage file (no caching since data is already in merkle tree).
//
export async function computeAssetHash(filePath: string, fileStat: IFileStat, openStream: (() => NodeJS.ReadableStream) | undefined): Promise<IHashedData> {
    //
    // Compute the hash of the file.
    //
    const hash = await computeHash(openStream ? openStream() : fs.createReadStream(filePath));
    return {
        hash,
        lastModified: fileStat.lastModified,
        length: fileStat.length,
    };
}
