import fs from "fs-extra";
import os from "os";
import path from "path";
import { IBsonCollection } from "bdb";
import { retry, IUuidGenerator, log } from "utils";
import { IAsset } from "defs";
import { getHashFromCache, computeCachedHash } from "./hash";
import { HashCache } from "./hash-cache";
import { FileScanner, IFileStat } from "./file-scanner";
import { ProgressCallback, IAddSummary } from "./media-file-database";

//
// Checks if a file has already been added to the database by computing its hash and looking it up in the metadata collection.
//
async function checkFile(
    uuidGenerator: IUuidGenerator,
    metadataCollection: IBsonCollection<IAsset>,
    localHashCache: HashCache,
    localFileScanner: FileScanner,
    filePath: string,
    fileStat: IFileStat,
    contentType: string,
    openStream: (() => NodeJS.ReadableStream) | undefined,
    progressCallback: ProgressCallback,
    summary: IAddSummary
): Promise<IAddSummary> {
    let localHashedFile = await getHashFromCache(filePath, fileStat, localHashCache);
    if (!localHashedFile) {          
        const tempDir = path.join(os.tmpdir(), `photosphere`, `check`);
        await fs.ensureDir(tempDir);

        const hashResult = await computeCachedHash(uuidGenerator, localHashCache, localFileScanner, filePath, fileStat, contentType, tempDir, openStream, progressCallback, summary);
        if (!hashResult.hashedFile) {
            return hashResult.summary;
        }
        localHashedFile = hashResult.hashedFile;
    }

    const localHashStr = localHashedFile.hash.toString("hex");
    const records = await metadataCollection.findByIndex("hash", localHashStr);
    if (records.length > 0) {
        log.verbose(`File "${filePath}" with hash "${localHashStr}", matches existing records:\n  ${records.map(r => r._id).join("\n  ")}`);
        summary.filesAlreadyAdded++;
        return summary;
    }

    log.verbose(`File "${filePath}" has not been added to the media file database.`);

    summary.filesAdded++;
    summary.totalSize += fileStat.length;
    if (progressCallback) {
        progressCallback(localFileScanner.getCurrentlyScanning());
    }
    
    return summary;
}

//
// Checks a list of files or directories to find files already added to the media file database.
//
export async function checkPaths(
    uuidGenerator: IUuidGenerator,
    metadataCollection: IBsonCollection<IAsset>,
    localHashCache: HashCache,
    localFileScanner: FileScanner,
    paths: string[],
    progressCallback: ProgressCallback,
    summary: IAddSummary = {
        filesAdded: 0,
        filesAlreadyAdded: 0,
        filesIgnored: 0,
        filesFailed: 0,
        totalSize: 0,
        averageSize: 0,
    }
): Promise<IAddSummary> {
    await localFileScanner.scanPaths(paths, async (result) => {
        await checkFile(
            uuidGenerator,
            metadataCollection,
            localHashCache,
            localFileScanner,
            result.filePath,
            result.fileStat,
            result.contentType,
            result.openStream,
            progressCallback,
            summary
        );
        
        if (summary.filesAdded % 100 === 0) {
            await retry(() => localHashCache.save());
        }
    }, progressCallback);

    await retry(() => localHashCache.save());
    summary.averageSize = summary.filesAdded > 0 ? Math.floor(summary.totalSize / summary.filesAdded) : 0;
    return summary;
}

