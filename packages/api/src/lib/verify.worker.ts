//
// Verify worker handler - handles file verification tasks
//

import { SortNode } from "merkle-tree";
import { createStorage, loadEncryptionKeysFromPem } from "storage";
import type { ITaskContext } from "task-queue";
import { computeAssetHash } from "./hash";
import { formatFileSize, log, retry } from "utils";
import { LARGE_FILE_TIMEOUT } from "./constants";
import { IDatabaseDescriptor } from "./database-descriptor";
import { resolveStorageCredentials } from "./resolve-storage-credentials";

export interface IVerifyFileData {
    node: SortNode;
    storageDescriptor: IDatabaseDescriptor;
    options?: {
        full?: boolean;
    };
}

export interface IVerifyFileResult {
    fileName: string;
    status: "unmodified" | "modified" | "removed" | "new";
    reasons?: string[];
}

//
// Handler for verifying a single file
//
export async function verifyFileHandler(data: IVerifyFileData, context: ITaskContext): Promise<IVerifyFileResult> {
    const { node, storageDescriptor, options } = data;
    const fileName = node.name!;

    const { s3Config, encryptionKeyPems } = await resolveStorageCredentials(storageDescriptor.databasePath, storageDescriptor.encryptionKey);
    const { options: storageOptions } = await loadEncryptionKeysFromPem(encryptionKeyPems);
    const { storage } = createStorage(storageDescriptor.databasePath, s3Config, storageOptions);

    const fileInfo = await retry(() => storage.info(fileName));
    if (!fileInfo) {
        return {
            fileName,
            status: "removed",
        };
    }

    const sizeChanged = node.size !== fileInfo.length;
    const timestampChanged = node.lastModified === undefined || node.lastModified!.getTime() !== fileInfo.lastModified.getTime();
    if (sizeChanged || timestampChanged) {
        // File metadata has changed - check if content actually changed by computing the hash.
        const freshHash = await retry(async () => computeAssetHash(await storage.readStream(fileName), fileInfo), 3, 1_000, 2, LARGE_FILE_TIMEOUT);
        if (Buffer.compare(freshHash.hash, node.contentHash!) !== 0) {
            // The file content has actually been modified.
            const reasons: string[] = [];
            if (sizeChanged) {
                const oldSize = formatFileSize(node.size);
                const newSize = formatFileSize(fileInfo.length);
                reasons.push(`size changed (${oldSize} → ${newSize})`);
            }
            if (timestampChanged) {
                const oldTime = node.lastModified!.toLocaleString();
                const newTime = fileInfo.lastModified.toLocaleString();
                reasons.push(`timestamp changed (${oldTime} → ${newTime})`);
            }
            reasons.push('content hash changed');
            
            if (log.verboseEnabled) {
                log.verbose(`Modified file: ${node.name} - ${reasons.join(', ')}`);
            }
            
            return {
                fileName,
                status: "modified",
                reasons
            };
        }
        else {
            // Metadata changed but content is the same - file is unmodified.
            return {
                fileName,
                status: "unmodified",
            };
        }
    }
    else {
        // File metadata hasn't changed - file is unmodified.
        return {
            fileName,
            status: "unmodified",
        };
    }
}

