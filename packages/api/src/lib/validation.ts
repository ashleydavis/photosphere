import { IFileInfo } from "storage";
import { getFileInfo } from "tools";
import fs from "fs-extra";

//
// Validates that a file is good before allowing it to be added to the merkle tree.
// filePath must be a path to a locally extracted file (not a zip file path).
//
export async function validateFile(filePath: string, contentType: string): Promise<boolean> {

    if (contentType === "image/vnd.adobe.photoshop") {
        // Not sure how to validate PSD files just yet.
        return true;
    }

    if (contentType.startsWith("image")) {
        return await validateImage(filePath, contentType);
    }
    else if (contentType.startsWith("video")) {
        return await validateVideo(filePath, contentType);
    }

    return true;
}

//
// Validates an image file by checking if it has valid dimensions
// filePath must be a path to a locally extracted file.
//
async function validateImage(filePath: string, contentType: string): Promise<boolean> {
    try {
        // Check that it's not a zero-byte file.
        const stats = await fs.stat(filePath);
        if (stats.size === 0) {
            console.error(`Invalid image ${filePath} - zero-byte file`);
            return false;
        }

        const fileInfo = await getFileInfo(filePath, contentType);
        if (!fileInfo) {
            console.error(`Invalid image ${filePath} - failed to get file info`);
            return false;
        }
        
        if (typeof fileInfo.dimensions.width === 'number' && typeof fileInfo.dimensions.height === 'number' && 
            fileInfo.dimensions.width > 0 && fileInfo.dimensions.height > 0) {
            return true;
        } else {
            console.error(`Invalid image ${filePath} - invalid dimensions: ${fileInfo.dimensions.width}x${fileInfo.dimensions.height}`);
            return false;
        }
    } catch (error) {
        console.error(`Invalid image ${filePath} - analysis failed: ${error instanceof Error ? error.message : 'Unknown error'}`);
        return false;
    }
}

//
// Validates a video file by checking if it has valid dimensions
// filePath must be a path to a locally extracted file.
//
async function validateVideo(filePath: string, contentType: string): Promise<boolean> {
    try {
        // Check that it's not a zero-byte file.
        const stats = await fs.stat(filePath);
        if (stats.size === 0) {
            console.error(`Invalid video ${filePath} - zero-byte file.`);
            return false;
        }

        const fileInfo = await getFileInfo(filePath, contentType);
        if (!fileInfo) {
            console.error(`Invalid video ${filePath} - failed to get file info`);
            return false;
        }
        
        if (typeof fileInfo.dimensions.width === 'number' && typeof fileInfo.dimensions.height === 'number' && 
            fileInfo.dimensions.width > 0 && fileInfo.dimensions.height > 0) {
            return true;
        } else {
            console.error(`Invalid video ${filePath} - invalid dimensions: ${fileInfo.dimensions.width}x${fileInfo.dimensions.height}`);
            return false;
        }
    } catch (error) {
        console.error(`Invalid video ${filePath} - analysis failed: ${error instanceof Error ? error.message : 'Unknown error'}`);
        return false;
    }
}

