//
// Verify worker handler - handles file verification tasks
//

import { SortNode } from "merkle-tree";
import { createStorage, loadEncryptionKeys, IStorageDescriptor } from "storage";
import { getS3Config } from "./config";
import { computeAssetHash } from "api";
import { formatFileSize, log } from "utils";

export interface IVerifyFileData {
    node: SortNode;
    storageDescriptor: IStorageDescriptor; // Storage descriptor containing location and encryption info
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
export async function verifyFileHandler(data: IVerifyFileData, workingDirectory: string): Promise<IVerifyFileResult> {
    const { node, storageDescriptor, options } = data;
    const fileName = node.name!;

    // Recreate the storage in the worker (storage objects can't be passed through worker messages)
    // S3 config is loaded from environment/config, and encryption key path comes from the storage descriptor
    const s3Config = await getS3Config();
    const { options: storageOptions } = await loadEncryptionKeys(storageDescriptor.encryptionKeyPath, false);
    const { storage: assetStorage } = createStorage(storageDescriptor.location, s3Config, storageOptions);

    const fileInfo = await assetStorage.info(fileName);
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
        const freshHash = await computeAssetHash(fileName, fileInfo, () => assetStorage.readStream(fileName));
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

