import * as os from "os";
import * as path from "path";
import { ensureDir, remove } from "node-utils";
import { IStorageDescriptor, IS3Credentials } from "storage";
import type { ITaskContext } from "task-queue";
import { swallowError } from "utils";
import { scanPaths } from "./file-scanner";
import { IHashFileData } from "./import.worker";

//
// Payload for the add-paths task. Contains the paths to scan plus the configuration
// needed by downstream import-file tasks.
//
export interface IAddPathsData {
    // Filesystem paths (files or directories) to import.
    paths: string[];

    // Identifies the target database and encryption keys.
    storageDescriptor: IStorageDescriptor;

    // Google Maps API key for reverse geocoding (optional).
    googleApiKey?: string;

    // Unique identifier for the session, used to acquire the write lock.
    sessionId: string;

    // When true, files are scanned and hashed but not written to the database.
    dryRun: boolean;

    // S3 credentials when the database is hosted in cloud storage (optional).
    s3Config?: IS3Credentials;
}

//
// Handler for the add-paths task. Scans filesystem paths for media files and queues
// an import-file task for each file found. Returns void; downstream tasks run independently.
//
export async function addPathsHandler(data: IAddPathsData, context: ITaskContext): Promise<void> {
    const { paths, storageDescriptor, googleApiKey, sessionId, dryRun, s3Config } = data;
    const { uuidGenerator } = context;
    const hashCacheDir = path.join(os.tmpdir(), "photosphere");
    const sessionTempDir = path.join(os.tmpdir(), "photosphere", uuidGenerator.generate());

    await ensureDir(sessionTempDir);

    try {
        // Track how many files have been reported as ignored so we can emit one
        // file-ignored message per newly ignored file (scanPaths reports a cumulative count).
        let prevIgnoredCount = 0;

        await scanPaths(
            paths,
            async (result) => {
                if (context.isCancelled()) {
                    return;
                }

                context.queueTask("import-file", {
                    filePath: result.filePath,
                    fileStat: result.fileStat,
                    contentType: result.contentType,
                    storageDescriptor,
                    hashCacheDir,
                    s3Config,
                    logicalPath: result.logicalPath,
                    labels: result.labels,
                    googleApiKey,
                    sessionId,
                    dryRun,
                    assetId: uuidGenerator.generate(),
                } satisfies IHashFileData, data.sessionId);
            },
            (currentlyScanning, state) => {
                const newIgnored = state.numFilesIgnored - prevIgnoredCount;
                prevIgnoredCount = state.numFilesIgnored;

                for (let idx = 0; idx < newIgnored; idx++) {
                    context.sendMessage({ type: "file-ignored" });
                }

                if (currentlyScanning) {
                    context.sendMessage({ type: "scan-progress", currentPath: currentlyScanning });
                }
            },
            { ignorePatterns: [/\.db/] },
            sessionTempDir,
            uuidGenerator
        );
    }
    finally {
        await swallowError(() => remove(sessionTempDir));
    }
}
