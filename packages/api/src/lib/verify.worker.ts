//
// Verify worker handler - handles file verification tasks
//

import { SortNode } from "merkle-tree";
import { createStorage, loadEncryptionKeys, IStorageDescriptor, IS3Credentials } from "storage";
import type { ITaskContext } from "task-queue";
import { computeAssetHash } from "./hash";
import { formatFileSize, log, retry } from "utils";

export interface IVerifyFileData {
    node: SortNode;
    storageDescriptor: IStorageDescriptor; // Storage descriptor containing location and encryption info
    s3Config?: IS3Credentials; // S3 config for accessing S3-hosted storage
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
    const { node, storageDescriptor, s3Config, options } = data;
    const fileName = node.name!;

    // Recreate the storage in the worker (storage objects can't be passed through worker messages)
    // S3 config is passed in the data, and encryption key path comes from the storage descriptor
    const { options: storageOptions } = await loadEncryptionKeys(storageDescriptor.encryptionKeyPath, false);
    const { storage: assetStorage } = createStorage(storageDescriptor.dbDir, s3Config, storageOptions);

    const fileInfo = await retry(() => assetStorage.info(fileName));
    if (!fileInfo) {
        // The file doesn't exist in the storage.
        log.warn(`File "${fileName}" is missing, even though we just found it by walking the directory.`);
        return {
            fileName,
            status: "removed",
        };
    }

    const sizeChanged = node.size !== fileInfo.length;
    const timestampChanged = node.lastModified === undefined || node.lastModified!.getTime() !== fileInfo.lastModified.getTime();             
    if (sizeChanged || timestampChanged) {
        // File metadata has changed - check if content actually changed by computing the hash.
        const freshHash = await retry(() => computeAssetHash(assetStorage.readStream(fileName), fileInfo));
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
        } else {
            // Metadata changed but content is the same - file is unmodified.
            return {
                fileName,
                status: "unmodified",
            };
        }
    } else {
        // File metadata hasn't changed - file is unmodified.
        return {
            fileName,
            status: "unmodified",
        };
    }
}

