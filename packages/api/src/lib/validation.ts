import { IFileInfo } from "storage";
import { getFileInfo } from "tools";
import { IUuidGenerator } from "utils";
import { writeStreamToFile } from "node-utils";
import fs from "fs-extra";
import path from "path";

//
// Validates that a file is good before allowing it to be added to the merkle tree.
//
export async function validateFile(filePath: string, contentType: string, tempDir: string, uuidGenerator: IUuidGenerator, openStream?: () => NodeJS.ReadableStream): Promise<boolean> {

    if (contentType === "image/vnd.adobe.photoshop") {
        // Not sure how to validate PSD files just yet.
        return true;
    }

    if (contentType.startsWith("image")) {
        return await validateImage(filePath, contentType, tempDir, uuidGenerator, openStream);
    }
    else if (contentType.startsWith("video")) {
        return await validateVideo(filePath, contentType, tempDir, uuidGenerator, openStream);
    }

    return true;
}

//
// Validates an image file by checking if it has valid dimensions
//
async function validateImage(filePath: string, contentType: string, tempDir: string, uuidGenerator: IUuidGenerator, openStream?: () => NodeJS.ReadableStream): Promise<boolean> {
    let tempFilePath: string | undefined;
    let actualFilePath = filePath;

    try {
        // If openStream is provided, we need to extract to a temporary file
        if (openStream) {
            tempFilePath = await extractToTempFile(openStream, tempDir, 'temp_image', path.extname(filePath), uuidGenerator);
            actualFilePath = tempFilePath;
        }

        // We now have a file in the file system.
        // Check that it's not a zero-byte file.
        const stats = await fs.stat(actualFilePath);
        if (stats.size === 0) {
            console.error(`Invalid image ${filePath} - zero-byte file`);
            return false;
        }

        const fileInfo = await getFileInfo(actualFilePath, contentType);
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
    } finally {
        // Clean up temporary file if created
        if (tempFilePath) {
            try {
                await fs.unlink(tempFilePath);
            } catch (err) {
                // Ignore cleanup errors
            }
        }
    }
}

//
// Validates a video file by checking if it has valid dimensions
//
async function validateVideo(filePath: string, contentType: string, tempDir: string, uuidGenerator: IUuidGenerator, openStream?: () => NodeJS.ReadableStream): Promise<boolean> {
    let tempFilePath: string | undefined;
    let actualFilePath = filePath;

    try {
        // If openStream is provided, we need to extract to a temporary file
        if (openStream) {
            tempFilePath = await extractToTempFile(openStream, tempDir, 'temp_video', path.extname(filePath), uuidGenerator);
            actualFilePath = tempFilePath;
        }

        // We now have a file in the file system.
        // Check that it's not a zero-byte file.
        const stats = await fs.stat(actualFilePath);
        if (stats.size === 0) {
            console.error(`Invalid video ${filePath} - zero-byte file.`);
            return false;
        }

        const fileInfo = await getFileInfo(actualFilePath, contentType);
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
    } finally {
        // Clean up temporary file if created
        if (tempFilePath) {
            try {
                await fs.unlink(tempFilePath);
            } catch (err) {
                // Ignore cleanup errors
            }
        }
    }
}

//
// Extracts stream data to a temporary file and returns the file path
//
async function extractToTempFile(openStream: () => NodeJS.ReadableStream, tempDir: string, prefix: string, ext: string, uuidGenerator: IUuidGenerator): Promise<string> {
    if (!ext.startsWith('.')) {
        ext = `.${ext}`;
    }
    const tempPath = path.join(tempDir, `${prefix}_${uuidGenerator.generate()}${ext}`);
    const inputStream = openStream();
    await writeStreamToFile(inputStream, tempPath);
    if (!await fs.exists(tempPath)) {
        throw new Error(`Failed to create temporary file at ${tempPath}`);
    }
    return tempPath;
}

