//
// Bun worker for processing file operations
// This worker handles hashing, validation, and metadata extraction
//

import { createHash } from "node:crypto";
import fs from "fs-extra";
import { getFileInfo } from "tools";

//
// Worker message types
//
type WorkerMessage = {
    taskId: string;
    type: 'hash' | 'validate';
    filePath: string;
    contentType?: string;
    tempDir?: string;
};

//
// Worker response types
//
type WorkerResponse = {
    taskId: string;
    result?: any;
    error?: string;
};

//
// Handles hash computation
//
async function computeFileHash(filePath: string): Promise<Buffer> {
    return new Promise<Buffer>((resolve, reject) => {
        const hash = createHash("sha256");
        const stream = fs.createReadStream(filePath);

        stream.on("data", (chunk: string | Buffer) => {
            hash.update(chunk);
        });

        stream.on("end", () => {
            resolve(hash.digest());
        });

        stream.on("error", (error) => {
            reject(error);
        });
    });
}

//
// Handles file validation
//
async function validateFile(filePath: string, contentType: string, tempDir: string): Promise<{ valid: boolean; error?: string }> {
    try {
        if (contentType === "image/vnd.adobe.photoshop") {
            // Not sure how to validate PSD files just yet.
            return { valid: true };
        }

        if (contentType.startsWith("image")) {
            return await validateImage(filePath, contentType);
        } else if (contentType.startsWith("video")) {
            return await validateVideo(filePath, contentType);
        }

        return { valid: true };
    } catch (error) {
        return {
            valid: false,
            error: error instanceof Error ? error.message : String(error),
        };
    }
}

//
// Validates an image file
//
async function validateImage(filePath: string, contentType: string): Promise<{ valid: boolean; error?: string }> {
    try {
        const stats = await fs.stat(filePath);
        if (stats.size === 0) {
            return { valid: false, error: "Zero-byte file" };
        }

        const fileInfo = await getFileInfo(filePath, contentType);
        if (!fileInfo) {
            return { valid: false, error: "Failed to get file info" };
        }

        if (
            typeof fileInfo.dimensions.width === 'number' &&
            typeof fileInfo.dimensions.height === 'number' &&
            fileInfo.dimensions.width > 0 &&
            fileInfo.dimensions.height > 0
        ) {
            return { valid: true };
        } else {
            return {
                valid: false,
                error: `Invalid dimensions: ${fileInfo.dimensions.width}x${fileInfo.dimensions.height}`,
            };
        }
    } catch (error) {
        return {
            valid: false,
            error: error instanceof Error ? error.message : String(error),
        };
    }
}

//
// Validates a video file
//
async function validateVideo(filePath: string, contentType: string): Promise<{ valid: boolean; error?: string }> {
    try {
        const stats = await fs.stat(filePath);
        if (stats.size === 0) {
            return { valid: false, error: "Zero-byte file" };
        }

        const fileInfo = await getFileInfo(filePath, contentType);
        if (!fileInfo) {
            return { valid: false, error: "Failed to get file info" };
        }

        if (
            typeof fileInfo.dimensions.width === 'number' &&
            typeof fileInfo.dimensions.height === 'number' &&
            fileInfo.dimensions.width > 0 &&
            fileInfo.dimensions.height > 0
        ) {
            return { valid: true };
        } else {
            return {
                valid: false,
                error: `Invalid dimensions: ${fileInfo.dimensions.width}x${fileInfo.dimensions.height}`,
            };
        }
    } catch (error) {
        return {
            valid: false,
            error: error instanceof Error ? error.message : String(error),
        };
    }
}


//
// Main worker message handler
//
self.onmessage = async (event: MessageEvent<WorkerMessage>) => {
    const { taskId, type, filePath, contentType, tempDir } = event.data;

    try {
        let result: any;

        switch (type) {
            case 'hash':
                const hash = await computeFileHash(filePath);
                result = { hash: hash.toString('base64') }; // Convert to base64 for transfer
                break;

            case 'validate':
                if (!contentType || !tempDir) {
                    throw new Error("contentType and tempDir required for validate task");
                }
                result = await validateFile(filePath, contentType, tempDir);
                break;

            default:
                throw new Error(`Unknown task type: ${(event.data as any).type}`);
        }

        const response: WorkerResponse = {
            taskId,
            result,
        };

        self.postMessage(response);
    } catch (error) {
        const response: WorkerResponse = {
            taskId,
            error: error instanceof Error ? error.message : String(error),
        };

        self.postMessage(response);
    }
};

