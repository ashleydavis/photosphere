import * as fsPromises from "fs/promises";
import * as path from "path";
import { IStorage } from "storage";
import { ACTIVE_RETENTION_POLICY, IEvictionCandidate, IRetentionContext, loadDatabaseConfig, SizeBudgetRetentionPolicy } from "api";
import { IMerkleTree, iterateLeaves, SortNode } from "merkle-tree";
import type { ITaskContext } from "task-queue";
import { log } from "utils";
import { openStorage } from "./open-storage";
import { loadMerkleTree, saveMerkleTree } from "./tree";
import { IDatabaseMetadata } from "./media-file-database";

//
// Drops local original files that the origin already holds, so the local database can stay small.
//
// Only the original and the transcoded display copy go. The thumbnail and the micro thumbnail stay
// on the device, which is what keeps the gallery browsable with no network at all. An evicted
// original is fetched back from the origin on demand by LazyOriginStorage, which is why the
// database is marked partial the moment anything is evicted: that flag is what makes reads lazy and
// what stops verify reporting the now-absent files as corruption.
//

//
// Payload for the evict-originals task.
//
export interface IEvictOriginalsData {
    // Path of the local database to evict from.
    databasePath: string;

    // Identifies the session. Reserved for the write lock if eviction ever needs one.
    sessionId: string;

    // Keep local originals under this many bytes, instead of using the active retention policy.
    // Undefined uses ACTIVE_RETENTION_POLICY, which is what the desktop and mobile apps do. The CLI
    // exposes this as --evict-budget for anyone who wants a different cap on one machine without
    // rebuilding, and it is what lets the smoke tests exercise eviction with ordinary-sized photos
    // rather than needing more than the policy's default cap of test data.
    localOriginalBudgetBytes?: number;
}

//
// What an eviction run did.
//
export interface IEvictOriginalsResult {
    // The assets whose local original was dropped.
    evictedAssetIds: string[];

    // How many bytes were freed on the device.
    freedBytes: number;

    // Why nothing was evicted, when nothing was. Undefined when the run went ahead.
    skippedReason: string | undefined;
}

//
// One file the local database holds, as the merkle tree records it.
//
interface ILocalFile {
    // The hash the tree records for the file, lower-case hex.
    contentHash: string;

    // The size in bytes the tree records for the file.
    sizeBytes: number;

    // When the tree last saw the file change, in milliseconds since the epoch.
    lastModifiedMs: number;
}

//
// Every file in a merkle tree under one of the given directory prefixes, by name.
//
function indexTreeFiles(merkleTree: IMerkleTree<IDatabaseMetadata> | undefined, prefixes: string[]): Map<string, ILocalFile> {
    const files = new Map<string, ILocalFile>();
    if (!merkleTree) {
        return files;
    }

    for (const leaf of iterateLeaves<SortNode>(merkleTree.sort)) {
        if (!leaf.name || !leaf.contentHash) {
            continue;
        }
        if (!prefixes.some(prefix => leaf.name!.startsWith(prefix))) {
            continue;
        }
        files.set(leaf.name, {
            contentHash: leaf.contentHash.toString("hex").toLowerCase(),
            sizeBytes: leaf.size,
            lastModifiedMs: leaf.lastModified ? leaf.lastModified.getTime() : 0,
        });
    }

    return files;
}

//
// How many bytes are free on the filesystem holding the given path.
//
// Reports zero for a path that is not on a local filesystem (an S3 database, say), because there is
// no device to run out of space on. It never guesses: a filesystem it cannot measure is reported as
// unmeasurable by throwing, so a policy that reads free space cannot act on a made-up number.
//
export async function getDeviceFreeBytes(databasePath: string): Promise<number> {
    const localPath = databasePath.startsWith("fs:") ? databasePath.slice("fs:".length) : databasePath;
    if (localPath.includes("://") || databasePath.startsWith("s3:")) {
        return 0;
    }

    // A database directory that does not exist yet still sits on a filesystem, and that filesystem
    // is the one that can run out of space, so the nearest existing ancestor is what to measure.
    let candidatePath = path.resolve(localPath);
    for (;;) {
        try {
            const stats = await fsPromises.statfs(candidatePath);
            return stats.bavail * stats.bsize;
        }
        catch (error: any) {
            if (error.code !== "ENOENT") {
                throw error;
            }
        }

        const parentPath = path.dirname(candidatePath);
        if (parentPath === candidatePath) {
            throw new Error(`Could not measure free space for "${databasePath}": no ancestor directory of it exists.`);
        }
        candidatePath = parentPath;
    }
}

//
// The assets whose local original could be dropped, and how the device is placed.
//
export function buildEvictionCandidates(
    localFiles: Map<string, ILocalFile>,
    originFiles: Map<string, ILocalFile>
): IEvictionCandidate[] {
    const candidates: IEvictionCandidate[] = [];

    for (const [name, localFile] of localFiles) {
        if (!name.startsWith("asset/")) {
            continue;
        }

        const assetId = name.slice("asset/".length);
        const originFile = originFiles.get(name);

        candidates.push({
            assetId,
            originalSizeBytes: localFile.sizeBytes,
            importedAtMs: localFile.lastModifiedMs,
            // Nothing records when an asset was last looked at, so no policy may depend on it.
            lastViewedAtMs: undefined,
            confirmedOnOrigin: originFile !== undefined && originFile.contentHash === localFile.contentHash,
        });
    }

    return candidates;
}

//
// Deletes a file if it is there, and reports how many bytes went. A file that is already gone frees
// nothing and is not an error: that is the state the caller wanted.
//
async function deleteIfPresent(storage: IStorage, filePath: string, sizeBytes: number): Promise<number> {
    if (!await storage.fileExists(filePath)) {
        return 0;
    }
    await storage.deleteFile(filePath);
    return sizeBytes;
}

//
// Drops the local originals the active retention policy selects.
//
export async function evictOriginalsHandler(data: IEvictOriginalsData, context: ITaskContext): Promise<IEvictOriginalsResult> {
    if (!data.databasePath) {
        throw new Error("databasePath is required");
    }

    const { storage: localStorage, rawStorage: localRawStorage } = await openStorage(data.databasePath);

    const config = await loadDatabaseConfig(localRawStorage);
    if (!config?.origin) {
        // With nowhere to fetch an evicted original back from, dropping it would lose it.
        return { evictedAssetIds: [], freedBytes: 0, skippedReason: "no origin configured" };
    }

    const localMerkleTree = await loadMerkleTree(localStorage);
    if (!localMerkleTree) {
        return { evictedAssetIds: [], freedBytes: 0, skippedReason: "no local merkle tree" };
    }

    const { storage: originStorage } = await openStorage(config.origin);
    const originMerkleTree = await loadMerkleTree(originStorage);
    if (!originMerkleTree) {
        return { evictedAssetIds: [], freedBytes: 0, skippedReason: `origin not accessible (${config.origin})` };
    }

    const localFiles = indexTreeFiles(localMerkleTree, ["asset/", "display/"]);
    const originFiles = indexTreeFiles(originMerkleTree, ["asset/", "display/"]);

    const candidates = buildEvictionCandidates(localFiles, originFiles);

    let totalLocalOriginalBytes = 0;
    for (const candidate of candidates) {
        totalLocalOriginalBytes += candidate.originalSizeBytes;
    }

    const retentionContext: IRetentionContext = {
        totalLocalOriginalBytes,
        deviceFreeBytes: await getDeviceFreeBytes(data.databasePath),
        nowMs: Date.now(),
    };

    const policy = data.localOriginalBudgetBytes === undefined
        ? ACTIVE_RETENTION_POLICY
        : new SizeBudgetRetentionPolicy(data.localOriginalBudgetBytes);

    const selectedAssetIds = policy.selectForEviction(candidates, retentionContext);
    const confirmedAssetIds = new Set(
        candidates.filter(candidate => candidate.confirmedOnOrigin).map(candidate => candidate.assetId)
    );

    const evictedAssetIds: string[] = [];
    let freedBytes = 0;

    for (const assetId of selectedAssetIds) {
        if (context.isCancelled()) {
            break;
        }

        // The policy is not trusted with the one rule that matters. A policy with a bug that
        // selected an unconfirmed asset would delete the user's only copy, so it is checked here as
        // well as inside every policy.
        if (!confirmedAssetIds.has(assetId)) {
            log.error(`Retention policy selected asset ${assetId} for eviction, but the origin does not hold a matching original. Keeping it.`);
            continue;
        }

        const originalName = `asset/${assetId}`;
        freedBytes += await deleteIfPresent(localStorage, originalName, localFiles.get(originalName)?.sizeBytes ?? 0);

        // The display copy goes only if the origin holds a matching one of its own. Thumbnails and
        // micro thumbnails are never touched: they are what keeps the gallery usable offline.
        const displayName = `display/${assetId}`;
        const localDisplay = localFiles.get(displayName);
        const originDisplay = originFiles.get(displayName);
        if (localDisplay && originDisplay && localDisplay.contentHash === originDisplay.contentHash) {
            freedBytes += await deleteIfPresent(localStorage, displayName, localDisplay.sizeBytes);
        }

        evictedAssetIds.push(assetId);
    }

    if (evictedAssetIds.length > 0 && localMerkleTree.databaseMetadata?.isPartial !== true) {
        // Originals are now missing locally and are fetched from the origin on demand, which is
        // exactly what partial means. Recording it is what makes reads lazy and stops verify
        // treating the absent files as damage.
        localMerkleTree.databaseMetadata = {
            ...localMerkleTree.databaseMetadata ?? { filesImported: 0 },
            isPartial: true,
        };
        await saveMerkleTree(localMerkleTree, localStorage);
    }

    return { evictedAssetIds, freedBytes, skippedReason: undefined };
}
