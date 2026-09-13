import { IBsonCollection, IBsonDatabase, IInternalRecord, IRecord, mergeRecords, toExternal } from "bdb";
import type { IAsset } from "api";
import type { ISyncChange } from "api";
import { compareTrees, deleteItem, findMerkleTreeDifferences, getItemInfo, IMerkleTree, upsertItem, buildMerkleTree, MerkleNode } from "merkle-tree";
import { IStorage, pathJoin } from "storage";
import { IDatabaseMetadata } from "./media-file-database";
import { acquireWriteLock, releaseWriteLock, loadDatabaseState, LARGE_FILE_TIMEOUT } from "api";
import { loadMerkleTree, saveMerkleTree, stampDatabaseState } from "./tree";
import { retry, retryOnce, log, FatalError, WrappedError } from "utils";
import { computeAssetHash } from "./hash";

//
// How long one step of a sync may take before the pass gives up on it.
//
// Generous, because these steps are slow on a phone and there is no harm in a long one finishing. It
// exists to put a floor under a step that will never finish at all: a pass that fails is ordinary and
// the loop runs another, while a pass that hangs stops syncing until the app is restarted.
//
const SYNC_STEP_TIMEOUT_MS = 30 * 60 * 1000;

//
// Runs one step of a sync under a deadline, naming it if the deadline passes.
//
async function retryOnceNamed<ReturnT>(step: () => Promise<ReturnT>, description: string): Promise<ReturnT> {
    try {
        return await retryOnce(step, SYNC_STEP_TIMEOUT_MS);
    }
    catch (error: any) {
        throw new WrappedError(`Sync gave up while ${description}`, { cause: error });
    }
}

//
// Result of a sync operation.
//
export interface ISyncResult {
    // True if a sync ran; false if the databases were already identical and the sync was skipped.
    synced: boolean;
}

//
// Syncs between source and target databases.
//
export async function syncDatabases(
    sourceAssetStorage: IStorage,
    sourceRawStorage: IStorage,
    sourceBsonDatabase: IBsonDatabase,
    targetAssetStorage: IStorage,
    targetRawStorage: IStorage,
    targetBsonDatabase: IBsonDatabase,
    sessionId: string,
    onLocalChange?: (change: ISyncChange) => void
): Promise<ISyncResult> {

    //
    // Fast early-out: if both databases report the same content hash they are identical, so there is
    // nothing to sync. Reading the two small state files avoids acquiring the remote write lock and
    // downloading the remote merkle trees when there are no differences.
    //
    const sourceState = await loadDatabaseState(sourceRawStorage);
    const targetState = await loadDatabaseState(targetRawStorage);
    if (sourceState?.contentHash && targetState?.contentHash
        && sourceState.contentHash.equals(targetState.contentHash)) {
        log.verbose("Databases have identical content hashes, skipping sync.");
        return { synced: false };
    }

    // The timestamp both sides record as their last successful sync.
    const syncedAt = new Date().toISOString();

    //
    // Pull incoming files.
    //
    await sourceBsonDatabase.flush();

    if (!await acquireWriteLock(sourceRawStorage, sessionId)) { //todo: Don't need write lock if nothing to pull.
        throw new Error(`Failed to acquire write lock for source database.`);
    }

    try {
        // Push files from target to source (effectively pulls files from target into source).
        // We are pulling files into the sourceDb, so need the write lock on the source db.
        // Each step is given a deadline and a name.
        //
        // A step that never finishes used to stop the sync for good, silently: measured on a Pixel 6,
        // a pass sat for nearly three hours at no CPU at all, having written nothing and logged
        // nothing, because the record merge and the commit had no timeout anywhere around them. A
        // pass that fails is ordinary and the loop runs another one; a pass that hangs is the end of
        // syncing until the app is restarted.
        const pull = await chooseHowToPushBytes(targetAssetStorage, targetRawStorage, sourceAssetStorage, sourceRawStorage);
        await retryOnceNamed(() => pushFiles(targetAssetStorage, sourceAssetStorage, sourceBsonDatabase, pull),
            "pulling files from the origin");
        const sourceMerkleTree = await retry(() => loadMerkleTree(sourceAssetStorage), 3, 1_000, 2, LARGE_FILE_TIMEOUT, "Failed to load the source merkle tree");
        const sourceDeletedIds = new Set(sourceMerkleTree?.databaseMetadata?.deletedAssetIds || []);
        await retryOnceNamed(() => syncDatabase(targetBsonDatabase, sourceBsonDatabase, sourceDeletedIds, onLocalChange),
            "merging the origin's records into this database");
        await retryOnceNamed(() => sourceBsonDatabase.commit(), "committing this database");

        // Refresh the source state file under the write lock we already hold (records the new content
        // hash and sync time), avoiding a second lock acquisition after the block.
        await retryOnceNamed(() => stampDatabaseState(sourceAssetStorage, sourceRawStorage, { lastSyncedAt: syncedAt }),
            "stamping this database's state");
    }
    finally {
        await releaseWriteLock(sourceRawStorage);
    }

    //
    // Push outgoing files.
    //
    await targetBsonDatabase.flush();

    if (!await acquireWriteLock(targetRawStorage, sessionId)) { //todo: Don't need write lock if nothing to push.
        throw new Error(`Failed to acquire write lock for target database.`);
    }

    try {
        // Push files from source to target.
        // Need the write lock in the target database.
        // No deadline on this one, unlike every other step: it is the whole point of a sync, it
        // copies every file the origin is missing, and on a phone with a real library that is hours
        // of work. The copies inside it have their own deadline, one per file, which is where a
        // stuck upload is caught. A deadline here caught nothing but honest progress: thirty minutes
        // in it gave up on a push that was uploading steadily.
        const push = await chooseHowToPushBytes(sourceAssetStorage, sourceRawStorage, targetAssetStorage, targetRawStorage);
        await pushFiles(sourceAssetStorage, targetAssetStorage, targetBsonDatabase, push);
        const targetMerkleTree = await retry(() => loadMerkleTree(targetAssetStorage), 3, 1_000, 2, LARGE_FILE_TIMEOUT, "Failed to load the target merkle tree");
        const targetDeletedIds = new Set(targetMerkleTree?.databaseMetadata?.deletedAssetIds || []);
        await retryOnceNamed(() => syncDatabase(sourceBsonDatabase, targetBsonDatabase, targetDeletedIds),
            "merging this database's records into the origin");
        await retryOnceNamed(() => targetBsonDatabase.commit(), "committing the origin");

        // Refresh the target state file under the write lock we already hold. Both sides now hold the
        // same (merged) content, so their content hashes match and the next sync can early-out.
        await retryOnceNamed(() => stampDatabaseState(targetAssetStorage, targetRawStorage, { lastSyncedAt: syncedAt }),
            "stamping the origin's state");
    }
    finally {
        await releaseWriteLock(targetRawStorage);
    }

    return { synced: true };
}

//
// Extracts asset ID from a file path.
// Asset files are stored with the asset ID as the filename, potentially in nested directories.
// Examples: "asset/abc123" -> "abc123", "directory/subdirectory/abc123" -> "abc123"
// Returns the asset ID (the last part of the path), or undefined if the path is empty.
//
function extractAssetId(filePath: string): string | undefined {
    if (!filePath) {
        return undefined;
    }
    const parts = filePath.split('/').filter(part => part.length > 0);
    // Asset ID is always the last part of the path (the filename)
    if (parts.length > 0) {
        return parts[parts.length - 1];
    }
    return undefined;
}

//
// A file the source's tree describes that the target's does not, or does not under the same hash.
//
interface IFileToConsider {
    // The file's name in both trees.
    name: string;

    // The hash the source's tree records for it.
    hash: Buffer;
}

//
// Where a push reads each file's bytes from and writes them to.
//
// Usually the two asset storages themselves, which hand out and take in what the database holds.
// When both databases are encrypted under the same key, the raw storages underneath instead: the
// ciphertext one holds is exactly the ciphertext the other would write, so it goes across as it is,
// with no decryption on the way out and no encryption on the way in.
//
// On a phone those two are the whole cost of pushing an original. AES-256-CBC there runs in the
// embedded engine's own JavaScript at about a fifth of a megabyte a second in each direction, so a
// push of twenty originals measured on a Pixel 6 moved 48MB in 472 seconds, about 100KB/s on a
// network that carries 11.8MB/s from the same phone, and a ninety megabyte video was a quarter of an
// hour. The bytes themselves, sent as they are stored, go from the file to the socket natively.
//
export interface IPushBytes {
    // The storage each file's bytes are read from.
    source: IStorage;

    // The storage each file's bytes are written to.
    target: IStorage;

    // True when the bytes are the stored ones, going across untouched, rather than what the
    // databases hold. The hash the target is handed is then of the stored bytes, taken from the
    // source's copy, since the tree's hash is of what the database holds and would not match.
    verbatim: boolean;
}

//
// A push that moves what the databases hold: read out of one asset storage, written into the other.
//
export function throughTheDatabases(sourceAssetStorage: IStorage, targetAssetStorage: IStorage): IPushBytes {
    return {
        source: sourceAssetStorage,
        target: targetAssetStorage,
        verbatim: false,
    };
}

//
// Decides how a push moves each file's bytes between two databases, given the storages they are
// read through and the raw storages underneath them.
//
// Verbatim, between the raw storages, when both databases are encrypted under the same key. Each
// encrypted database carries `.db/encryption.pub` naming the key its files are written under, and it
// is rewritten only once every file has been re-encrypted under a new one, so two databases whose
// key files are the same byte for byte hold files either could read. Otherwise through the asset
// storages, which decrypt and encrypt on the way as they always have. A database that is not
// encrypted has no key file, so a pair with one such side is never verbatim.
//
export async function chooseHowToPushBytes(sourceAssetStorage: IStorage, sourceRawStorage: IStorage, targetAssetStorage: IStorage, targetRawStorage: IStorage): Promise<IPushBytes> {
    const sourceKey = await retry(() => sourceRawStorage.read(".db/encryption.pub"));
    const targetKey = await retry(() => targetRawStorage.read(".db/encryption.pub"));
    if (sourceKey !== undefined && targetKey !== undefined && Buffer.compare(sourceKey, targetKey) === 0) {
        return {
            source: sourceRawStorage,
            target: targetRawStorage,
            verbatim: true,
        };
    }

    return throughTheDatabases(sourceAssetStorage, targetAssetStorage);
}

//
// Pushes from source db to target db for a particular device based
// on missing files detected by comparing source and target merkle trees.
//
export async function pushFiles(sourceAssetStorage: IStorage, targetAssetStorage: IStorage, targetBsonDatabase: IBsonDatabase, bytes: IPushBytes): Promise<void> {

    //
    // Load the merkle tree.
    //
    const sourceMerkleTree = await retry(() => loadMerkleTree(sourceAssetStorage), 3, 1_000, 2, LARGE_FILE_TIMEOUT, "Failed to load the source merkle tree to push from");
    if (!sourceMerkleTree) {
        throw new Error("Failed to load source merkle tree.");
    }

    let targetMerkleTree = await retry(() => loadMerkleTree(targetAssetStorage), 3, 1_000, 2, LARGE_FILE_TIMEOUT, "Failed to load the target merkle tree to push into");
    if (!targetMerkleTree) {
        throw new Error("Failed to load target merkle tree.");
    }

    // Check that source and target databases have the same ID.
    if (sourceMerkleTree.id !== targetMerkleTree.id) {
        throw new FatalError(
            `You are trying to sync databases that have different IDs.\n` +
            `Source database ID: ${sourceMerkleTree.id}\n` +
            `Target database ID: ${targetMerkleTree.id}\n` + 
            `The databases are not related to each other.`
        );
    }

    // Don't do anything if the source and target merkle trees are identical.
    if (sourceMerkleTree.merkle && targetMerkleTree.merkle 
        && Buffer.compare(sourceMerkleTree.merkle.hash, targetMerkleTree.merkle.hash) === 0) {
        log.verbose("Source and target merkle trees are identical, no sync needed.");
        return;
    }
   
    // Get deleted asset IDs from source and target
    const sourceDeletedIds = new Set(sourceMerkleTree.databaseMetadata?.deletedAssetIds || []);
    const targetDeletedIds = new Set(targetMerkleTree.databaseMetadata?.deletedAssetIds || []);
   
    let filesCopied = 0;

    // Files that could not be copied this pass. They stay missing at the far end, so the next pass
    // finds them in the difference and tries them again.
    let filesLeftBehind = 0;

    // What filesCopied stood at when the tree was last saved and when the timings were last said.
    //
    // Both of those happen every so many files, and both are checked once per leaf rather than once
    // per copy, so a count sitting on a multiple repeated them for every leaf walked and matched
    // afterwards. Measured on a Pixel 6 pushing to an origin holding thousands of photos, the timings
    // line came out five times in a row for leaves 417 to 421 with the count stuck at sixty, and the
    // tree save does the same thing at every hundredth file, which is a megabyte written back per
    // leaf to record that nothing changed.
    let filesCopiedAtLastTreeSave = 0;
    let filesCopiedAtLastTimingsLine = 0;

    // Where the time goes, in milliseconds, reported every so often while a push runs.
    //
    // Without it a slow sync is a number of files a minute and nothing else. The import path has the
    // same thing for the same reason: its unmeasured remainder turned out to be 54% of an import.
    let millisecondsAskingAboutTheSource = 0;
    let millisecondsWriting = 0;
    let millisecondsUpdatingTheTree = 0;
    let millisecondsSavingTheTree = 0;
    let millisecondsDiffingTheTrees = 0;
    let millisecondsDecidingWhetherToCopy = 0;
    let millisecondsInsideCopyFile = 0;
    let millisecondsOpeningTheSource = 0;
    let leavesVisited = 0;
    let nodesVisited = 0;
    let millisecondsLogging = 0;
    let bytesCopied = 0;
    const pushStartedAt = Date.now();

    //
    // Says where the push's time has gone so far.
    //
    // A sync that is slow is otherwise just a number of files a minute, and the interesting figure is
    // always the one that does not belong: a pass that spent forty-six minutes of its forty-six
    // minutes writing the merkle tree said so here and nowhere else.
    //
    const sayWhereTheTimeWent = (): void => {
        const loggedAt = Date.now();
        const elapsed = Date.now() - pushStartedAt;
        const unaccounted = elapsed - millisecondsAskingAboutTheSource - millisecondsWriting
            - millisecondsUpdatingTheTree - millisecondsSavingTheTree
            - millisecondsDiffingTheTrees - millisecondsDecidingWhetherToCopy - millisecondsLogging;
        log.info(`Sync timings: ${JSON.stringify({
            filesCopied,
            leavesVisited,
            nodesVisited,
            bytesCopied,
            elapsedMs: elapsed,
            copyFileMs: millisecondsInsideCopyFile,
            diffMs: millisecondsDiffingTheTrees,
            decideMs: millisecondsDecidingWhetherToCopy,
            openSourceMs: millisecondsOpeningTheSource,
            sourceInfoMs: millisecondsAskingAboutTheSource,
            writeMs: millisecondsWriting,
            treeUpdateMs: millisecondsUpdatingTheTree,
            treeSaveMs: millisecondsSavingTheTree,
            loggingMs: millisecondsLogging,
            unaccountedMs: unaccounted,
        })}`);
        millisecondsLogging += Date.now() - loggedAt;
    };

    //
    // Copies a single file if necessary.
    //
    const copyFile = async (fileName: string, sourceHash: Buffer): Promise<void> => {
        const decidingStartedAt = Date.now();
        leavesVisited++;

        // Check if target database is partial - if so, only copy thumb directory files and root-level files
        const isTargetPartial = targetMerkleTree?.databaseMetadata?.isPartial === true;
        if (isTargetPartial) {
            const normalizedFileName = fileName.replace(/\\/g, '/');
            const isThumbFile = normalizedFileName.startsWith('thumb/');
            const isRootFile = !normalizedFileName.includes('/');
            if (!isThumbFile && !isRootFile) {
                log.verbose(`Skipped ${fileName} (target database is partial, only thumb files and root files are copied)`);
                return;
            }
        }
        
        // Check if this asset is in the deleted list
        const assetId = extractAssetId(fileName);
        if (!assetId) {
            throw new Error(`Failed to extract asset ID from file name: ${fileName}`);
        }

        if (sourceDeletedIds.has(assetId) || targetDeletedIds.has(assetId)) {
            // Asset is deleted, skip copying it
            log.verbose(`Skipped deleted asset file: ${fileName}`);
            return;
        }

        // Check if file already exists in destination tree with matching hash.
        const targetFileInfo = getItemInfo(targetMerkleTree!, fileName);
        if (targetFileInfo && Buffer.compare(targetFileInfo.hash, sourceHash) === 0) {
            // File already exists with correct hash, skip copying.
            // This assumes the file is non-corrupted. To find corrupted files, a verify would be needed.
            millisecondsDecidingWhetherToCopy += Date.now() - decidingStartedAt;
            return;
        }
        millisecondsDecidingWhetherToCopy += Date.now() - decidingStartedAt;

        // Get file info from source.
        const askedAboutTheSourceAt = Date.now();
        const sourceFileInfo = await sourceAssetStorage.info(fileName);
        if (!sourceFileInfo) {
            throw new Error(`Failed to find file ${fileName} in source database.`);
        }
        millisecondsAskingAboutTheSource += Date.now() - askedAboutTheSourceAt;

        // What the source's tree records for this file, which is what the target's tree is about to
        // record for its copy. Its hash is already trusted for exactly this file: it is what decided
        // the copy was needed and what goes up with the body.
        const sourceTreeInfo = getItemInfo(sourceMerkleTree, fileName);
        if (!sourceTreeInfo) {
            throw new Error(`Source file "${fileName}" is in the source tree's merkle nodes but not in its sort tree.`);
        }

        // Copy file from source to target.
        // The hash goes up with the file. It is already known, because it is what the merkle tree is
        // made of, and handing it over means nothing has to compute it: S3 checks the body against it
        // and refuses a write that does not match, while a store that cannot check it writes the
        // stream as usual. On a phone that is the difference between a sync and a stalled one, since
        // the SDK would otherwise hash every byte in the embedded engine's pure JavaScript SHA-256.
        //
        // What is sent, and what the target is told it is. Through the databases the stream is what
        // the database holds and the hash is the tree's, which is of exactly that. Verbatim, the
        // stream is the stored bytes themselves and the hash has to be of those, so it is taken from
        // the source's copy, natively where there is a native hasher: the tree's hash is of the
        // plaintext and would not match.
        //
        const openedAt = Date.now();
        const storedInfo = bytes.verbatim ? await bytes.source.info(fileName) : sourceFileInfo;
        if (!storedInfo) {
            throw new Error(`Failed to find the stored bytes of ${fileName} in the source database.`);
        }
        const hashForTheStore = bytes.verbatim
            ? (await computeAssetHash(await bytes.source.readStream(fileName), storedInfo)).hash
            : sourceHash;
        const readStream = await bytes.source.readStream(fileName);
        millisecondsOpeningTheSource += Date.now() - openedAt;
        // A store that checked the bytes against the hash as it wrote them has already told us
        // everything a check afterwards could, so nothing else is asked of it.
        //
        // Asking cost two more round trips per file, on top of the write: one to learn the file is
        // there and how long it is, another to read back the hash the server had just verified. On a
        // phone, where every request is a fresh connection and a response crosses the engine bridge,
        // those two were a large part of the time a file took. A store that cannot check (a
        // filesystem, or encrypted storage, whose stored bytes are ciphertext and hash to something
        // else) is still asked, and the copy is checked by its length. `psi verify` is the deep
        // check, and it reads everything deliberately rather than as a side effect of every sync.
        //
        // How many bytes that stream will produce, which is the source's to say and not the same as
        // the size of the file it keeps.
        //
        // An encrypted database holds ciphertext and reads out plaintext, and it cannot say how long
        // the plaintext is without decrypting the file, so it says it cannot. Handing the stored size
        // over instead made the target declare a Content-Length it then fell short of by the
        // encryption's overhead, and S3 sat waiting for a remainder that was never coming: measured
        // on a Pixel 6 pushing to MinIO on the same LAN, every file failed after thirty seconds with
        // "A timeout occurred while trying to lock a resource, please reduce your request rate",
        // three attempts each, and the sync copied nothing at all for as long as it was left running.
        //
        const writeStartedAt = Date.now();
        const verifiedByTheStore = await bytes.target.writeStreamHashed(fileName, sourceFileInfo.contentType, readStream, bytes.source.readableLength(storedInfo), hashForTheStore);
        millisecondsWriting += Date.now() - writeStartedAt;
        bytesCopied += sourceTreeInfo.length;

        if (!verifiedByTheStore) {
            const copiedFileInfo = await bytes.target.info(fileName);
            if (!copiedFileInfo) {
                throw new Error(`Failed to copy ${fileName} to target db.`);
            }

            const storedHash = await bytes.target.storedHash(fileName);
            if (storedHash !== undefined) {
                if (Buffer.compare(storedHash, hashForTheStore) !== 0) {
                    throw new Error(`Hash of copied file ${fileName} is different to the source hash.`);
                }
            }
            else if (copiedFileInfo.length !== storedInfo.length) {
                throw new Error(`Copied file ${fileName} is ${copiedFileInfo.length} bytes at the target and ${storedInfo.length} at the source.`);
            }
        }

        // Add or update file in target merkle tree, under what the source's tree recorded: the copy
        // has just been checked against that hash, so the two describe the same bytes, and the length
        // and time are the source tree's for the same reason. Reading them back off the target would
        // be another request per file to be told what was just sent, and off an encrypted target it
        // would give the ciphertext's length, which would never match the source and would put the
        // file back in the difference on every pass for ever.
        const treeStartedAt = Date.now();
        targetMerkleTree = upsertItem(targetMerkleTree!, {
            name: fileName,
            hash: sourceHash,
            length: sourceTreeInfo.length,
            lastModified: sourceTreeInfo.lastModified,
        });
        millisecondsUpdatingTheTree += Date.now() - treeStartedAt;

        filesCopied++;
        
        log.verbose(`Copied file: ${fileName}`);
    };
    
    //
    // The files to consider: every file the source's tree describes that the target's does not, or
    // describes under a different hash, found by name.
    //
    // This used to be the merkle diff, and the merkle diff matches leaves by hash rather than by
    // name, so a file whose content the target already held under another name was never offered
    // for copying at all. A library holds such files whenever a photo has been imported twice: an
    // import stopped before its batch was written imports the same photos again under new ids on
    // its next run, and the records for the new ids reach the target through the record merge while
    // their files never do. Measured on a Pixel 6 against an origin holding 15,491 files, 243 files
    // of 101 assets were missing at the origin after five passes that had each reported nothing
    // left behind, and only a walk of both trees by name said so.
    //
    const decidingWhatToConsiderAt = Date.now();
    const comparison = compareTrees(sourceMerkleTree, targetMerkleTree);
    const filesToConsider: IFileToConsider[] = [];
    for (const name of comparison.onlyInA.concat(comparison.modified)) {
        const info = getItemInfo(sourceMerkleTree, name);
        if (!info) {
            throw new Error(`The source tree compared as holding ${name} and then did not have it.`);
        }
        filesToConsider.push({
            name,
            hash: info.hash,
        });
    }
    nodesVisited = filesToConsider.length;
    millisecondsDiffingTheTrees += Date.now() - decidingWhatToConsiderAt;

    for (const file of filesToConsider) {
        // The long timeout is the one the import path already uses for streaming large files
        // to S3. Left at retry's thirty second default, every copy of a file that takes
        // longer than that was abandoned and tried again from the start: on a Pixel 6, which
        // pushes about seven megabytes a minute through the engine bridge, that is anything
        // over about three megabytes, so a library with a video in it never finished syncing
        // and the same file was uploaded over and over for ever.
        // A file that will not copy is left behind rather than taken as the end of the sync.
        //
        // The rest of the library has nothing to do with it, and abandoning the pass on the
        // first bad file means everything after that file in the tree never goes anywhere:
        // measured on a Pixel 6 against a real library, one video that the server kept
        // refusing held up all 2,292 assets, pass after pass, for as long as it was left
        // running. The file stays missing at the far end, so the next pass finds it in the
        // difference and tries it again.
        try {
            const copyStartedAt = Date.now();
            await retry(() => copyFile(file.name, file.hash), 3, 1_000, 2, LARGE_FILE_TIMEOUT,
                `Failed to copy file ${file.name}`);
            millisecondsInsideCopyFile += Date.now() - copyStartedAt;
        }
        catch (error: any) {
            filesLeftBehind++;
            log.exception(`Failed to copy ${file.name}, carrying on with the rest of the sync`, error);
            continue;
        }

        // Save the target merkle tree every hundred files, so a push that is interrupted
        // does not start again from nothing.
        //
        // Comparing against the count at the last save is what makes that "every hundred
        // files" rather than "every leaf". This is reached once per leaf, and a leaf whose
        // file is already at the far end copies nothing, so a count resting on a multiple of
        // a hundred saved the whole tree again for each of them. Measured on a Pixel 6
        // pushing to an S3 origin holding thousands of photos, a pass that had nothing to
        // copy spent 42 minutes visiting 92 leaves, of which 10 milliseconds was the copying:
        // the rest was serializing and uploading a megabyte of merkle tree, once per leaf, to
        // record that nothing had changed. A count of zero is the starting value, so a pass
        // that has copied nothing yet saves nothing.
        if (filesCopied % 100 === 0 && filesCopied !== filesCopiedAtLastTreeSave) {
            filesCopiedAtLastTreeSave = filesCopied;
            const savedAt = Date.now();
            await retry(() => saveMerkleTree(targetMerkleTree!, targetAssetStorage), 3, 1_000, 2, LARGE_FILE_TIMEOUT, "Failed to save the target merkle tree part way through a push");
            millisecondsSavingTheTree += Date.now() - savedAt;
        }

        // Where the time went, said out loud often enough to be useful and rarely enough to
        // be readable. A sync that is slow is otherwise just a number of files a minute.
        //
        // Against the count at the last line for the reason above: this is reached once per
        // leaf, so a count resting on a multiple of twenty said the same thing again for
        // every leaf walked and matched afterwards. On a Pixel 6 pushing to an origin holding
        // thousands of photos that was five identical lines for leaves 417 to 421, and the
        // line that mattered was somewhere under them.
        if (filesCopied % 20 === 0 && filesCopied !== filesCopiedAtLastTimingsLine) {
            filesCopiedAtLastTimingsLine = filesCopied;
            sayWhereTheTimeWent();
        }
    }
    
    // Delete assets that are marked as deleted in source (but not yet deleted in target)
    // Iterate through source's deleted list and delete each asset from target
    let assetsDeleted = 0;
    for (const assetId of sourceDeletedIds) {
        // Skip if already deleted in target
        if (targetDeletedIds.has(assetId)) {
            continue;
        }
        
        // Delete the asset files
        const assetPath = pathJoin("asset", assetId);
        const displayPath = pathJoin("display", assetId);
        const thumbPath = pathJoin("thumb", assetId);
        
        // Try to delete files (may not exist, which is fine)
        await targetAssetStorage.deleteFile(assetPath).catch(() => {});
        await targetAssetStorage.deleteFile(displayPath).catch(() => {});
        await targetAssetStorage.deleteFile(thumbPath).catch(() => {});
        
        // Remove from the target merkle tree
        deleteItem<IDatabaseMetadata>(targetMerkleTree, assetPath);
        deleteItem<IDatabaseMetadata>(targetMerkleTree, displayPath);
        deleteItem<IDatabaseMetadata>(targetMerkleTree, thumbPath);
            
        // Remove from metadata collection
        const metadataCollection = targetBsonDatabase.collection("metadata");
        await metadataCollection.deleteOne(assetId);
        
        // Ensure databaseMetadata exists
        if (!targetMerkleTree.databaseMetadata) {
            targetMerkleTree.databaseMetadata = { filesImported: 0 };
        }

        // Decrement filesImported count
        if (targetMerkleTree.databaseMetadata.filesImported > 0) {
            targetMerkleTree.databaseMetadata.filesImported--;
        }
        
        assetsDeleted++;
        
        // Add to target's deleted list
        if (!targetMerkleTree.databaseMetadata.deletedAssetIds) {
            targetMerkleTree.databaseMetadata.deletedAssetIds = [];
        }

        targetMerkleTree.databaseMetadata.deletedAssetIds.push(assetId);
        
        log.verbose(`Deleted asset ${assetId} from target (marked as deleted in source)`);
    }
    
    // Save the target merkle tree one final time, and only when this pass put something in it.
    //
    // Nothing copied and nothing deleted leaves the tree exactly as it was loaded, so writing it back
    // sends a megabyte to say that. On a Pixel 6 pushing to an origin holding 8,481 photos that one
    // write took twenty-nine seconds of a thirty-one second pass, every five minutes, for as long as
    // the app was running: it is the whole cost of a sync that has nothing to do, and it was
    // competing for the connection with the import that did.
    if (filesCopied > 0 || assetsDeleted > 0) {
        const savedAt = Date.now();
        await retry(() => saveMerkleTree(targetMerkleTree!, targetAssetStorage), 3, 1_000, 2, LARGE_FILE_TIMEOUT, "Failed to save the target merkle tree after a push");
        millisecondsSavingTheTree += Date.now() - savedAt;
    }


    // Said once at the end whatever the pass did, because a pass that copied nothing is exactly the
    // one whose time needs explaining and is the one the every-twenty-files line above never reaches.
    sayWhereTheTimeWent();

    log.info(`Push completed: ${filesCopied} files copied, ${filesLeftBehind} left behind for the next pass, ${assetsDeleted} deleted from target`);
}

//
// Generator to extract leaf node names from MerkleNode arrays.
//
function* iterateLeaves(nodes: MerkleNode[]): Generator<string> { //todo: This could be a shared function in the merkle-tree package.
    for (const node of nodes) {
        if (!node.left && !node.right) {
            if (!node.name) {
                throw new Error("Leaf node has no name");
            }
            yield node.name;
        } else {
            if (node.left) {
                yield* iterateLeaves([node.left]);
            }
            if (node.right) {
                yield* iterateLeaves([node.right]);
            }
        }
    }
}

//
// Identifies a differing record between source and target databases, used as the yield type for sync diff generators.
//
interface ISyncDiffRecord {
    collectionName: string;
    recordId: string;
    sourceRecord?: IInternalRecord;
    targetRecord?: IInternalRecord;
}

//
// Yields differing records for a specific collection and shard.
//
async function* iterateShardDifferences(
    collectionName: string,
    shardId: string,
    sourceCollection: IBsonCollection<IRecord>,
    targetCollection: IBsonCollection<IRecord>,
    sourceShardTree: IMerkleTree<undefined> | undefined,
    targetShardTree: IMerkleTree<undefined> | undefined
): AsyncGenerator<ISyncDiffRecord> {

    const diff = findMerkleTreeDifferences(sourceShardTree?.merkle, targetShardTree?.merkle);
    const sourceShard = sourceCollection.shard(shardId);
    const targetShard = targetCollection.shard(shardId);

    // Extract record IDs from both sets to detect modifications
    const recordIdsInTree1 = new Set(iterateLeaves(diff.onlyInTree1));
    const recordIdsInTree2 = new Set(iterateLeaves(diff.onlyInTree2));

    const sourceRecords = await sourceShard.records();
    const targetRecords = await targetShard.records();

    // Track record IDs we've already yielded to avoid duplicates
    const seenRecordIds = new Set<string>();
    
    // Process records from tree1
    for (const recordId of recordIdsInTree1) {
        seenRecordIds.add(recordId);
        const normalizedId = recordId.replace(/-/g, ''); //todo: This is a bit ugly.
        const sourceRecord = sourceRecords.get(normalizedId);
        const targetRecord = targetRecords.get(normalizedId);

        // If record ID appears in both trees, it's modified (different hash)
        // Otherwise, it's only in source
        yield {
            collectionName,
            recordId,
            sourceRecord,
            targetRecord,
        };
    }
    
    // Process records only in tree2 (not already processed above)
    for (const recordId of recordIdsInTree2) {
        if (seenRecordIds.has(recordId)) {
            continue; // Already processed as a modification
        }
        
        const normalizedId = recordId.replace(/-/g, ''); //todo: This is a bit ugly.
        const sourceRecord = sourceRecords.get(normalizedId);
        const targetRecord = targetRecords.get(normalizedId);
        yield {
            collectionName,
            recordId,
            sourceRecord,
            targetRecord,
        };
    }
}

//
// Yields differing records for a specific collection.
//
async function* iterateCollectionDifferences(
    collectionName: string,
    sourceCollection: IBsonCollection<IRecord>,
    targetCollection: IBsonCollection<IRecord>,
    sourceCollectionTree: IMerkleTree<undefined> | undefined,
    targetCollectionTree: IMerkleTree<undefined> | undefined
): AsyncGenerator<ISyncDiffRecord> {
    const diff = findMerkleTreeDifferences(sourceCollectionTree?.merkle, targetCollectionTree?.merkle);
    
    // Track shard keys we've seen to avoid duplicates (only track, don't collect all)
    const seenShardKeys = new Set<string>();
    
    // Process shards only in source
    for (const shardId of iterateLeaves(diff.onlyInTree1)) {
        seenShardKeys.add(shardId);

        const sourceShardTree = await sourceCollection.shard(shardId).merkleTree().get();
        const targetShardTree = await targetCollection.shard(shardId).merkleTree().get();
        if (!sourceShardTree && !targetShardTree) {
            continue;
        }
        
        yield* iterateShardDifferences(collectionName, shardId, sourceCollection, targetCollection, sourceShardTree, targetShardTree);
    }
    
    // Process shards only in target or modified
    for (const shardId of iterateLeaves(diff.onlyInTree2)) {
        if (seenShardKeys.has(shardId)) {
            continue; // Already processed
        }

        const sourceShardTree = await sourceCollection.shard(shardId).merkleTree().get();
        const targetShardTree = await targetCollection.shard(shardId).merkleTree().get();
        if (!sourceShardTree && !targetShardTree) {
            continue;
        }

        yield* iterateShardDifferences(collectionName, shardId, sourceCollection, targetCollection, sourceShardTree, targetShardTree);
    }
}

//
// Yields differing records in the BSON database.
//
async function* iterateDatabaseDifferences( //todo: todo this could be in the bdb package and tested.
    sourceDb: IBsonDatabase,
    targetDb: IBsonDatabase,
): AsyncGenerator<ISyncDiffRecord> {
    const sourceDbTree = await sourceDb.merkleTree().get();
    const targetDbTree = await targetDb.merkleTree().get();
    if (!sourceDbTree && !targetDbTree) {
        return;
    }
    
    const diff = findMerkleTreeDifferences(sourceDbTree?.merkle, targetDbTree?.merkle);
    
    // Track collections we've seen to avoid duplicates (only track, don't collect all)
    const seenCollections = new Set<string>();
    
    // Process collections only in source
    for (const collectionName of iterateLeaves(diff.onlyInTree1)) {
        seenCollections.add(collectionName);

        const sourceCollection = sourceDb.collection(collectionName);
        const targetCollection = targetDb.collection(collectionName);
        const sourceCollectionTree = await sourceCollection.merkleTree().get();
        const targetCollectionTree = await targetCollection.merkleTree().get();

        if (!sourceCollectionTree && !targetCollectionTree) {
            continue;
        }
        
        yield* iterateCollectionDifferences(
            collectionName,
            sourceCollection,
            targetCollection,
            sourceCollectionTree,
            targetCollectionTree,
        );
    }
    
    // Process collections only in target or modified
    for (const collectionName of iterateLeaves(diff.onlyInTree2)) {
        if (seenCollections.has(collectionName)) {
            continue; // Already processed
        }
        
        const sourceCollection = sourceDb.collection(collectionName);
        const targetCollection = targetDb.collection(collectionName);
        const sourceCollectionTree = await sourceCollection.merkleTree().get();
        const targetCollectionTree = await targetCollection.merkleTree().get();

        if (!sourceCollectionTree && !targetCollectionTree) {
            continue;
        }

        yield* iterateCollectionDifferences(
            collectionName,
            sourceCollection,
            targetCollection,
            sourceCollectionTree,
            targetCollectionTree,
        );
    }
}

//
// Syncs database records from source to target using hierarchical merkle-tree based diffing.
// targetDeletedIds: asset IDs that have been intentionally deleted from the target database.
// Records whose IDs are in this set will not be inserted into the target even if they exist in source.
//
export async function syncDatabase(
    sourceBsonDatabase: IBsonDatabase,
    targetBsonDatabase: IBsonDatabase,
    targetDeletedIds: Set<string>,
    onLocalChange?: (change: ISyncChange) => void
): Promise<void> {
    const sourceDbTree = await sourceBsonDatabase.merkleTree().get();
    const targetDbTree = await targetBsonDatabase.merkleTree().get();

    if (sourceDbTree?.merkle && targetDbTree?.merkle) { //todo: move this comparison to the iterateDatabaseDifferences function.
        if (Buffer.compare(sourceDbTree.merkle.hash, targetDbTree.merkle.hash) === 0) {
            log.verbose("Databases are identical, no sync needed.");
            return;
        }
    }
    
    log.info("Finding differing records using hierarchical merkle trees...");
    
    let mergedCount = 0;
    
    // Process differing records as they're found (using generator)
    for await (const diff of iterateDatabaseDifferences(sourceBsonDatabase, targetBsonDatabase)) {

        const targetCollection = targetBsonDatabase.collection(diff.collectionName);        

        if (diff.sourceRecord && diff.targetRecord) {
            // Both records exist, merge them.
            const merged = mergeRecords(diff.sourceRecord, diff.targetRecord);
            // Use setInternalRecord to preserve all timestamps exactly
            await targetCollection.setInternalRecord(merged);
            mergedCount++;
            if (onLocalChange && diff.collectionName === "metadata") {
                onLocalChange({ type: "updated", asset: toExternal<IAsset>(merged) });
            }
        }
        else if (diff.sourceRecord) {
            // Record only in source - insert it unless the target intentionally deleted it.
            if (!targetDeletedIds.has(diff.sourceRecord._id)) {
                await targetCollection.setInternalRecord(diff.sourceRecord);
                mergedCount++;
                if (onLocalChange && diff.collectionName === "metadata") {
                    onLocalChange({ type: "added", asset: toExternal<IAsset>(diff.sourceRecord) });
                }
            }
            else {
                if (onLocalChange && diff.collectionName === "metadata") {
                    onLocalChange({ type: "deleted", assetId: diff.sourceRecord._id });
                }
            }
        }
        else if (diff.targetRecord) {
            // Record only in target, nothing to do (target already has it)
            // This case is less common in sync scenarios
        }
        
        if (mergedCount % 100 === 0) {
            log.verbose(`Merged ${mergedCount} records...`);
        }
    }
    
    if (mergedCount === 0) {
        log.info("No differing records found.");
    }
    else {
        log.info(`Sync completed: ${mergedCount} records merged.`);
    }
}
