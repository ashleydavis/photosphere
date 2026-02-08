import { log, retry } from "utils";
import { ProgressCallback } from "./media-file-database";
import { SortNode, traverseTreeAsync } from "merkle-tree";
import { loadMerkleTree } from "./tree";
import { IStorage, IStorageDescriptor, IS3Credentials } from "storage";
import { TaskStatus } from "task-queue";
import { IVerifyFileData } from "./verify.worker";
import type { ITaskQueueProvider } from "task-queue";
import { verify as verifySerializedFile } from "serialization";

//
// Options for verifying the media file database.
//
export interface IVerifyOptions {
    //
    // Enables full verification where all files are re-hashed.
    //
    full?: boolean;

    //
    // Path filter to only verify files matching this path (file or directory).
    //
    pathFilter?: string;

    //
    // Optional S3 configuration for accessing S3-hosted storage.
    //
    s3Config?: IS3Credentials;
}

//
// Result of the verification process.
//
export interface IVerifyResult {
    //
    // The total number of files imported into the database.
    //
    totalImports: number;

    //
    // The total number of files verified (including thumbnails, display, BSON, etc.).
    //
    totalFiles: number;

    //
    // The total database size.
    //
    totalSize: number;

    //
    // The number of files that were unmodified.
    //
    numUnmodified: number;

    //
    // The number of files that failed to verify.
    //
    numFailures: number;

    //
    // The list of files that were modified.
    //
    modified: string[];

    //
    // The list of new files that were added to the database.
    //
    new: string[];

    //
    // The list of files that were removed from the database.
    //
    removed: string[];

    //
    // The number of files that were processed from the file system.
    // 
    filesProcessed: number;

    //
    // The number of nodes processed in the merkle tree.
    //
    nodesProcessed: number;
}

//
// Verifies the media file database.
// Checks for missing files, modified files, and new files.
// If any files are corrupted, this will pick them up as modified.
//
export async function verify(storageDescriptor: IStorageDescriptor, databaseStorage: IStorage, taskQueueProvider: ITaskQueueProvider, options?: IVerifyOptions, progressCallback?: ProgressCallback) : Promise<IVerifyResult> {

    let pathFilter = options?.pathFilter 
        ? options.pathFilter.replace(/\\/g, '/') // Normalize path separators
        : undefined;

    // Load the merkle tree once and reuse it throughout the verification process
    const merkleTree = await retry(() => loadMerkleTree(databaseStorage));
    if (!merkleTree) {
        throw new Error(`Failed to load merkle tree`);
    }

    const totalFiles = merkleTree.sort?.leafCount || 0;
    const result: IVerifyResult = {
        totalImports: merkleTree.databaseMetadata?.filesImported || 0,
        totalFiles,
        totalSize: merkleTree.sort?.size || 0,
        numUnmodified: 0,
        numFailures: 0,
        modified: [],
        new: [],
        removed: [],
        filesProcessed: 0,
        nodesProcessed: 0,
    };

    //
    // Check the merkle tree to find files that have been removed.
    //
    if (progressCallback) {
        if (options?.pathFilter) {
            progressCallback(`Verifying files matching: ${options.pathFilter}`);
        } else {
            progressCallback(`Verifying files...`);
        }
    }

    //
    // Result from verifying a single file.
    //
    interface IVerifyFileResult {
        fileName: string;
        status: "removed" | "modified" | "unmodified";
        reasons?: string[];
    }

    //
    // Get the task queue from the provider (lazily created).
    // Handlers are registered in the worker file (apps/cli/src/lib/worker.ts).
    // maxWorkers is set in the provider constructor (defaults to number of CPUs).
    //
    const queue = await taskQueueProvider.create();

    try {
        //
        // Registers a callback to integrate results as tasks complete.
        //
        queue.onTaskComplete<IVerifyFileData, IVerifyFileResult>((task, taskResult) => {

            result.filesProcessed++;
            
            if (taskResult.status === TaskStatus.Succeeded) {
                const fileResult = taskResult.outputs!;

                if (progressCallback) {
                    const status = queue.getStatus();
                    progressCallback(`Verified file ${result.filesProcessed} of ${totalFiles} (${status.running} tasks running in parallel)`);
                }

                if (fileResult.status === "removed") {
                    // For partial databases, ignore missing files (they're expected to be missing)
                    if (!isPartial) {
                        result.removed.push(fileResult.fileName);
                    }
                    else {
                        // Count as unmodified since missing files are expected in partial databases
                        result.numUnmodified++;
                    }
                }
                else if (fileResult.status === "modified") {
                    result.modified.push(fileResult.fileName);
                }
                else {
                    result.numUnmodified++;
                }
            } 
            else if (taskResult.status === TaskStatus.Failed) {
                const fileName = task.data.node.name ?? "unknown";
                if (taskResult.error) {
                    log.exception(`Failed to verify file "${fileName}": ${taskResult.errorMessage}`, taskResult.error);
                } 
                else {
                    log.error(`Failed to verify file "${fileName}": ${taskResult.errorMessage}`);
                }
                result.numFailures++;
            }
        });

        //
        // Check if database is partial - missing files should be ignored for partial databases
        //
        const isPartial = merkleTree.databaseMetadata?.isPartial === true;

        //
        // Queue up all verification tasks as quickly as possible.
        // Pass the storage descriptor instead of the storage object (which can't be serialized).
        // Filter nodes by pathFilter before queuing tasks.
        //
        await traverseTreeAsync<SortNode>(merkleTree.sort, async (node) => {
            result.nodesProcessed++;

            if (node.name) {
                // Apply path filter before queuing the task
                if (pathFilter && !node.name.startsWith(pathFilter)) {
                    return true; // Skip this node
                }

                queue.addTask("verify-file", {
                    node,
                    storageDescriptor,
                    s3Config: options?.s3Config,
                    options: {
                        full: options?.full,
                    },
                });
            }

            return true;
        });

        //
        // Wait for all tasks to complete.
        //
        await queue.awaitAllTasks();

        return result;
    }
    finally {
        queue.shutdown();
    }
}

//
// Result from verifying database files.
//
export interface IDatabaseFileVerifyResult {
    totalFiles: number;
    totalSize: number;
    validFiles: number;
    invalidFiles: string[];
    errors: { file: string; error: string }[];
}


//
// Verifies all database files (merkle trees, metadata collection, sort indexes).
// Checks size and checksum for each file.
//
// @param metadataStorage - Unencrypted storage scoped to .db/ directory (for files.dat)
// @param databaseStorage - Storage rooted at database directory (scans metadata/ subdirectory; v6: .db/bson/)
//
export async function verifyDatabaseFiles(metadataStorage: IStorage, databaseStorage: IStorage, progressCallback?: ProgressCallback): Promise<IDatabaseFileVerifyResult> {
    const result: IDatabaseFileVerifyResult = {
        totalFiles: 0,
        totalSize: 0,
        validFiles: 0,
        invalidFiles: [],
        errors: [],
    };
    
    // Helper to add an error
    function addError(file: string, error: string) {
        result.invalidFiles.push(file);
        result.errors.push({ file, error });
    }
    
    //
    // Phase 1: Count all files to verify
    //
    if (progressCallback) {
        progressCallback("Verifying database files...");
    }
    
    let expectedTotal = 0;
    
    // Count files.dat (database merkle tree - metadataStorage is scoped to .db/)
    if (await metadataStorage.fileExists("files.dat")) {
        expectedTotal++;
    }
    
    // Count collection files (scan metadata/ subdirectory; v6: .db/bson/collections/)
    const metadataDirs = await databaseStorage.listDirs(".db/bson/collections", 1000);
    const collections = metadataDirs.names;
    for (const collectionName of collections) {
        const collectionDir = `.db/bson/collections/${collectionName}`;

        // Count collection.dat
        if (await databaseStorage.fileExists(`${collectionDir}/collection.dat`)) {
            expectedTotal++;
        }
        // Count all other files in the collection (v6: shards/ subdir)
        const collectionFiles = await databaseStorage.listFiles(`${collectionDir}/shards`, 10000);
        for (const fileName of collectionFiles.names) {
            expectedTotal++;
        }
    }
    // Count sort index files
    if (await databaseStorage.dirExists(".db/bson/indexes")) {
        const sortIndexCollections = await databaseStorage.listDirs(".db/bson/indexes", 1000);
        for (const collectionName of sortIndexCollections.names) {
            const sortIndexCollectionDir = `.db/bson/indexes/${collectionName}`;
            const indexDirs = await databaseStorage.listDirs(sortIndexCollectionDir, 1000);
            
            for (const indexDirName of indexDirs.names) {
                const indexDir = `${sortIndexCollectionDir}/${indexDirName}`;
                const indexFiles = await databaseStorage.listFiles(indexDir, 10000);
                // Exclude build.checkpoint files
                expectedTotal += indexFiles.names.filter(name => name !== "build.checkpoint").length;
            }
        }
    }
    
    // Helper to report progress
    let filesVerified = 0;
    function reportProgress() {
        filesVerified++;
        if (progressCallback) {
            progressCallback(`Verified database file ${filesVerified} of ${expectedTotal}`);
        }
    }
    
    //
    // Phase 2: Verify all files
    //
    
    // 1. Verify files.dat (database merkle tree - metadataStorage is scoped to .db/)
    
    if (await metadataStorage.fileExists("files.dat")) {
        log.verbose(`Verifying .db/files.dat`);
        result.totalFiles++;
        const verifyResult = await verifySerializedFile(metadataStorage, "files.dat"); //todo: various checks can be done in background tasks.
        result.totalSize += verifyResult.size;
        if (verifyResult.valid) {
            result.validFiles++;
        }
        else {
            addError("files.dat", verifyResult.error || "Unknown error");
        }
        reportProgress();
    }
    
    // 2. For each collection, verify all files
    for (const collectionName of collections) {
        const collectionDir = `.db/bson/collections/${collectionName}`;

        // 3a. Verify collection.dat (collection merkle tree - no checksum)
        const collectionDatPath = `${collectionDir}/collection.dat`;
        if (await databaseStorage.fileExists(collectionDatPath)) {
            log.verbose(`Verifying ${collectionDatPath}`);
            result.totalFiles++;
            const verifyResult = await verifySerializedFile(databaseStorage, collectionDatPath);
            result.totalSize += verifyResult.size;
            if (verifyResult.valid) {
                result.validFiles++;
            }
            else {
                addError(collectionDatPath, verifyResult.error || "Unknown error");
            }
            reportProgress();
        }
        // 3b. Get all files in the collection directory (v6: shards/ subdir)
        const collectionFiles = await databaseStorage.listFiles(`${collectionDir}/shards`, 10000);
        for (const fileName of collectionFiles.names) {
            const filePath = `${collectionDir}/shards/${fileName}`;
            result.totalFiles++;
            if (fileName.endsWith(".dat")) {
                // Shard merkle tree file (no checksum)
                log.verbose(`Verifying ${filePath}`);
                const verifyResult = await verifySerializedFile(databaseStorage, filePath);
                result.totalSize += verifyResult.size;
                if (verifyResult.valid) {
                    result.validFiles++;
                }
                else {
                    addError(filePath, verifyResult.error || "Unknown error");
                }
                reportProgress();
            }
            else {
                // Shard data file (with checksum)
                log.verbose(`Verifying ${filePath}`);
                try {
                    const verifyResult = await verifySerializedFile(databaseStorage, filePath);
                    result.totalSize += verifyResult.size;
                    if (verifyResult.valid) {
                        result.validFiles++;
                    }
                    else {
                        addError(filePath, verifyResult.error || "Unknown error");
                    }
                }
                catch (error: any) {
                    addError(filePath, error.message);
                }
                reportProgress();
            }
        }
    }
    
    // 4. Verify sort_indexes
    if (await databaseStorage.dirExists(".db/bson/indexes")) {
        const sortIndexCollections = await databaseStorage.listDirs(".db/bson/indexes", 1000);
        
        for (const collectionName of sortIndexCollections.names) {
            const sortIndexCollectionDir = `.db/bson/indexes/${collectionName}`;
            const indexDirs = await databaseStorage.listDirs(sortIndexCollectionDir, 1000);
            
            for (const indexDirName of indexDirs.names) {
                const indexDir = `${sortIndexCollectionDir}/${indexDirName}`;
                
                // Get all files in the index directory
                const indexFiles = await databaseStorage.listFiles(indexDir, 10000);                
                
                for (const fileName of indexFiles.names) {
                    // Skip build.checkpoint files
                    if (fileName === "build.checkpoint") {
                        continue;
                    }
                    
                    const filePath = `${indexDir}/${fileName}`;
                    result.totalFiles++;
                    
                    // files.dat and page files (all have checksum)
                    log.verbose(`Verifying ${filePath}`);
                    try {
                        const verifyResult = await verifySerializedFile(databaseStorage, filePath);
                        result.totalSize += verifyResult.size;
                        if (verifyResult.valid) {
                            result.validFiles++;
                        }
                        else {
                            addError(filePath, verifyResult.error || "Unknown error");
                        }
                    }
                    catch (error: any) {
                        addError(filePath, error.message);
                    }
                    reportProgress();
                }
            }
        }
    }
    
    // Ensure totalFiles reflects the expected total
    result.totalFiles = expectedTotal;
    
    return result;
}
