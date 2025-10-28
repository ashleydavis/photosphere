import { computeHash } from "adb";
import { IFileStat } from "./file-scanner";
import fs from "fs-extra";
import { IHashedData } from "merkle-tree";

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
