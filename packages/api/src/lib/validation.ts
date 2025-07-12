import { Readable } from "node:stream";
import { IFileInfo } from "storage";
import { getFileInfo } from "tools";
import { writeFileSync, unlinkSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { IUuidGenerator } from "utils";

//
// Validates that a file is good before allowing it to be added to the merkle tree.
//
export async function validateFile(filePath: string, fileInfo: IFileInfo, contentType: string, uuidGenerator: IUuidGenerator, openStream?: () => Readable): Promise<boolean> {

    if (contentType === "image/vnd.adobe.photoshop") {
        // Not sure how to validate PSD files just yet.
        return true;
    }

    if (contentType.startsWith("image")) {
        return await validateImage(filePath, contentType, uuidGenerator, openStream);
    }
    else if (contentType.startsWith("video")) {
        return await validateVideo(filePath, contentType, uuidGenerator, openStream);
    }

    return true;
}

//
// Validates an image file by checking if it has valid dimensions
//
async function validateImage(filePath: string, contentType: string, uuidGenerator: IUuidGenerator, openStream?: () => Readable): Promise<boolean> {
    let tempFilePath: string | undefined;
    let actualFilePath = filePath;

    try {
        // If openStream is provided, we need to extract to a temporary file
        if (openStream) {
            tempFilePath = await extractToTempFile(openStream, 'temp_image', uuidGenerator);
            actualFilePath = tempFilePath;
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
                unlinkSync(tempFilePath);
            } catch (err) {
                // Ignore cleanup errors
            }
        }
    }
}

//
// Validates a video file by checking if it has valid dimensions
//
async function validateVideo(filePath: string, contentType: string, uuidGenerator: IUuidGenerator, openStream?: () => Readable): Promise<boolean> {
    let tempFilePath: string | undefined;
    let actualFilePath = filePath;

    try {
        // If openStream is provided, we need to extract to a temporary file
        if (openStream) {
            tempFilePath = await extractToTempFile(openStream, 'temp_video', uuidGenerator);
            actualFilePath = tempFilePath;
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
                unlinkSync(tempFilePath);
            } catch (err) {
                // Ignore cleanup errors
            }
        }
    }
}

//
// Extracts stream data to a temporary file and returns the file path
//
async function extractToTempFile(openStream: () => Readable, prefix: string, uuidGenerator: IUuidGenerator): Promise<string> {
    const tempPath = join(tmpdir(), `${prefix}_${uuidGenerator.generate()}`);
    
    const inputStream = openStream();
    const chunks: Buffer[] = [];
    
    for await (const chunk of inputStream) {
        chunks.push(chunk);
    }
    
    const fileBuffer = Buffer.concat(chunks);
    writeFileSync(tempPath, fileBuffer);
    
    return tempPath;
}

