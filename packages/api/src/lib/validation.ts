import { getFileInfo } from "tools";
import { log } from "utils";
import { IFileStat } from "./file-scanner";

//
// Validates that a file is good before allowing it to be added to the merkle tree.
// filePath must be a path to a locally extracted file (not a zip file path).
//
export async function validateFile(filePath: string, contentType: string, fileStat: IFileStat): Promise<boolean> {
    // Check that it's not a zero-byte file.
    if (fileStat.length === 0) {
        log.error(`Invalid file ${filePath} - zero-byte file`);
        return false;
    }

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
        const fileInfo = await getFileInfo(filePath, contentType);
        if (!fileInfo) {
            log.error(`Invalid image ${filePath} - failed to get file info`);
            return false;
        }
        
        if (fileInfo.dimensions.width > 0 && fileInfo.dimensions.height > 0) {
            log.verbose(`Valid image ${filePath} - dimensions: ${fileInfo.dimensions.width}x${fileInfo.dimensions.height}`);
            return true;
        }
        else {
            log.error(`Invalid image ${filePath} - invalid dimensions: ${fileInfo.dimensions.width}x${fileInfo.dimensions.height}`);
            return false;
        }
    }
    catch (error: any) {
        log.exception(`Invalid image ${filePath} - analysis failed`, error);
        return false;
    }
}

//
// Validates a video file by checking if it has valid dimensions
// filePath must be a path to a locally extracted file.
//
async function validateVideo(filePath: string, contentType: string): Promise<boolean> {
    try {
        const fileInfo = await getFileInfo(filePath, contentType);
        if (!fileInfo) {
            log.error(`Invalid video ${filePath} - failed to get file info`);
            return false;
        }
        
        if (fileInfo.dimensions.width > 0 && fileInfo.dimensions.height > 0) {
            log.verbose(`Valid video ${filePath} - dimensions: ${fileInfo.dimensions.width}x${fileInfo.dimensions.height}`);
            return true;
        }
        else {
            log.error(`Invalid video ${filePath} - invalid dimensions: ${fileInfo.dimensions.width}x${fileInfo.dimensions.height}`);
            return false;
        }
    }
    catch (error: any) {
        log.exception(`Invalid video ${filePath} - analysis failed`, error);
        return false;
    }
}

