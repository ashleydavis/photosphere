import { BsonDatabase, IBsonDatabase } from "bdb";
import { acquireWriteLock, IAsset, releaseWriteLock, updateDatabaseConfig } from "api";
import { addItem, IMerkleTree, iterateLeaves, SortNode } from "merkle-tree";
import { IStorage } from "storage";
import { ITimestampProvider, IUuidGenerator, log, retry } from "utils";
import { IDatabaseMetadata } from "./media-file-database";
import { replicate } from "./replicate";
import { loadMerkleTree, saveMerkleTree, stampDatabaseModified } from "./tree";

//
// Joining a standalone local database to a remote that already has photos in it.
//
// Sync refuses to work between two databases that are not related, and this does not weaken that
// refusal: consolidation is a separate, explicit operation that makes them related. It works by
// content hash rather than by asset id, because two databases that grew up apart gave different ids
// to the same photo, and the id says nothing about whether the remote already has the content.
//
// Afterwards the local database is a partial replica of the remote: it has adopted the remote's
// database id, named it as its origin, and been marked partial, so ordinary sync applies from then
// on.
//

//
// The three kinds of file an asset has in storage. The micro thumbnail lives inside the metadata
// record, not in storage, so it is not listed here.
//
const ASSET_FILE_PREFIXES = ["asset/", "display/", "thumb/"];

//
// What consolidation would do, worked out from the two merkle trees alone.
//
export interface IConsolidationPlan {
    // Local assets whose original the remote does not hold. Their content and metadata are pushed.
    absentAssetIds: string[];

    // Local assets whose original the remote already holds under some id. Nothing of theirs is
    // pushed, because the remote's copy is the one that survives.
    presentAssetIds: string[];
}

//
// Every content hash a merkle tree holds an original for, lower-case hex.
//
function originalHashes(merkleTree: IMerkleTree<IDatabaseMetadata> | undefined): Set<string> {
    const hashes = new Set<string>();
    if (!merkleTree) {
        return hashes;
    }

    for (const leaf of iterateLeaves<SortNode>(merkleTree.sort)) {
        if (!leaf.name || !leaf.contentHash) {
            continue;
        }
        if (!leaf.name.startsWith("asset/")) {
            continue;
        }
        hashes.add(leaf.contentHash.toString("hex").toLowerCase());
    }

    return hashes;
}

//
// Works out which local assets the remote is missing, by content hash.
//
export function planConsolidation(
    localTree: IMerkleTree<IDatabaseMetadata> | undefined,
    remoteTree: IMerkleTree<IDatabaseMetadata> | undefined
): IConsolidationPlan {
    const remoteHashes = originalHashes(remoteTree);

    const absentAssetIds: string[] = [];
    const presentAssetIds: string[] = [];

    if (!localTree) {
        return { absentAssetIds, presentAssetIds };
    }

    for (const leaf of iterateLeaves<SortNode>(localTree.sort)) {
        if (!leaf.name || !leaf.contentHash) {
            continue;
        }
        if (!leaf.name.startsWith("asset/")) {
            continue;
        }

        const assetId = leaf.name.slice("asset/".length);
        if (remoteHashes.has(leaf.contentHash.toString("hex").toLowerCase())) {
            presentAssetIds.push(assetId);
        }
        else {
            absentAssetIds.push(assetId);
        }
    }

    return { absentAssetIds, presentAssetIds };
}

//
// What a consolidation run did.
//
export interface IConsolidationResult {
    // How many local assets were pushed to the remote.
    pushedCount: number;

    // How many local assets the remote already had, and were dropped locally in favour of the
    // remote's copy.
    alreadyPresentCount: number;

    // The database id the local database now shares with the remote.
    databaseId: string;
}

//
// Reports progress as consolidation works through the assets.
//
export type IConsolidationProgressCallback = (pushed: number, total: number) => void;

//
// Copies one file between storages if the source has it, and returns what it copied so the caller
// can record it in the destination's merkle tree.
//
async function copyAssetFile(fileName: string, sourceStorage: IStorage, destStorage: IStorage): Promise<boolean> {
    if (!await sourceStorage.fileExists(fileName)) {
        return false;
    }

    const info = await retry(() => sourceStorage.info(fileName));
    if (!info) {
        return false;
    }

    await retry(async () => {
        const readStream = await sourceStorage.readStream(fileName);
        await destStorage.writeStream(fileName, info.contentType, readStream);
    });

    return true;
}

//
// Pushes the local assets the remote does not have into it, drops the local copies of the ones it
// already has, and re-stamps the local database as a partial replica of the remote.
//
export async function consolidateDatabases(
    localPath: string,
    localStorage: IStorage,
    localRawStorage: IStorage,
    localBsonDatabase: IBsonDatabase,
    remotePath: string,
    remoteStorage: IStorage,
    remoteRawStorage: IStorage,
    remoteBsonDatabase: IBsonDatabase,
    sessionId: string,
    uuidGenerator: IUuidGenerator,
    timestampProvider: ITimestampProvider,
    onProgress: IConsolidationProgressCallback | undefined
): Promise<IConsolidationResult> {

    const localTree = await retry(() => loadMerkleTree(localStorage));
    if (!localTree) {
        throw new Error(`Failed to load the merkle tree of the local database at ${localPath}.`);
    }

    let remoteTree = await retry(() => loadMerkleTree(remoteStorage));
    if (!remoteTree) {
        throw new Error(`Failed to load the merkle tree of the remote database at ${remotePath}.`);
    }

    if (localTree.id === remoteTree.id) {
        // Already related, so there is nothing to consolidate: ordinary sync covers this case.
        return { pushedCount: 0, alreadyPresentCount: 0, databaseId: remoteTree.id };
    }

    const plan = planConsolidation(localTree, remoteTree);
    const localMetadata = localBsonDatabase.collection<IAsset>("metadata");
    const remoteMetadata = remoteBsonDatabase.collection<IAsset>("metadata");

    // --- Push what the remote does not have. ---

    await localBsonDatabase.flush();

    if (!await acquireWriteLock(remoteRawStorage, sessionId)) {
        throw new Error(`Failed to acquire the write lock on the remote database at ${remotePath}.`);
    }

    let pushedCount = 0;
    try {
        for (const assetId of plan.absentAssetIds) {
            const assetRecord = await localMetadata.getOne(assetId);
            if (!assetRecord) {
                // The tree names a file the metadata knows nothing about. Pushing the bytes with no
                // record would put an asset in the remote that nothing can show, so it is reported
                // and skipped rather than half-pushed.
                log.error(`Consolidation skipped asset ${assetId}: the local database has the file but no metadata record for it.`);
                continue;
            }

            for (const prefix of ASSET_FILE_PREFIXES) {
                const fileName = `${prefix}${assetId}`;
                if (!await copyAssetFile(fileName, localStorage, remoteStorage)) {
                    continue;
                }

                const info = await retry(() => remoteStorage.info(fileName));
                const localItem = localTree.sort ? findLeaf(localTree, fileName) : undefined;
                if (!info || !localItem || !localItem.contentHash) {
                    throw new Error(`Consolidation copied ${fileName} to the remote but could not record it in the remote's merkle tree.`);
                }

                remoteTree = addItem(remoteTree, {
                    name: fileName,
                    hash: localItem.contentHash,
                    length: localItem.size,
                    lastModified: localItem.lastModified ?? new Date(),
                });
            }

            await remoteMetadata.insertOne(assetRecord);
            pushedCount += 1;
            if (onProgress) {
                onProgress(pushedCount, plan.absentAssetIds.length);
            }
        }

        if (!remoteTree.databaseMetadata) {
            remoteTree.databaseMetadata = { filesImported: 0 };
        }
        remoteTree.databaseMetadata.filesImported += pushedCount;

        await retry(() => saveMerkleTree(remoteTree!, remoteStorage));
        await remoteBsonDatabase.commit();
        await stampDatabaseModified(remoteStorage, remoteRawStorage);
    }
    finally {
        await releaseWriteLock(remoteRawStorage);
    }

    // --- Make the local database a partial replica of the remote. ---

    if (!await acquireWriteLock(localRawStorage, sessionId)) {
        throw new Error(`Failed to acquire the write lock on the local database at ${localPath}.`);
    }

    try {
        // The local originals the remote already had are dropped. The remote's copy of that content
        // is the one that survives, under the remote's own asset id, and keeping the local file
        // would leave a copy nothing refers to.
        for (const assetId of plan.presentAssetIds) {
            for (const prefix of ASSET_FILE_PREFIXES) {
                const fileName = `${prefix}${assetId}`;
                if (await localStorage.fileExists(fileName)) {
                    await retry(() => localStorage.deleteFile(fileName));
                }
            }
        }

        // The local records go entirely, and the remote's take their place. Everything the local
        // database knew is now on the remote, either because it was pushed just now or because the
        // remote already had it, so nothing is lost. Leaving the local records in place would be
        // worse than useless: the merkle trees copied down next describe the remote's records, and
        // a stale local record file would be read in preference to fetching the remote's.
        await localStorage.deleteDir(".db/bson");

        // Replicating the remote down as a partial replica is what adopts the remote's database id,
        // its merkle trees and its record set in one step, and marks the local database partial so
        // the originals it does not hold are fetched from the origin when they are wanted. `force`
        // is needed precisely because the two ids differ: making them the same is the point.
        await replicate(
            remotePath,
            remoteStorage,
            remoteBsonDatabase as BsonDatabase,
            uuidGenerator,
            timestampProvider,
            localStorage,
            localRawStorage,
            { partial: true, force: true },
            undefined
        );

        await updateDatabaseConfig(localRawStorage, { origin: remotePath });
    }
    finally {
        await releaseWriteLock(localRawStorage);
    }

    return {
        pushedCount,
        alreadyPresentCount: plan.presentAssetIds.length,
        databaseId: remoteTree.id,
    };
}

//
// Finds the leaf for a file name in a merkle tree, or undefined when it is not there.
//
function findLeaf(merkleTree: IMerkleTree<IDatabaseMetadata>, fileName: string): SortNode | undefined {
    for (const leaf of iterateLeaves<SortNode>(merkleTree.sort)) {
        if (leaf.name === fileName) {
            return leaf;
        }
    }
    return undefined;
}
