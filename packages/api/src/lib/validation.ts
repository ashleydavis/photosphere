import { Readable } from "node:stream";
import { IFileInfo } from "storage";
import { Video, Image } from "tools";
import { writeFileSync, unlinkSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";

//
// Validates that a file is good before allowing it to be added to the merkle tree.
//
export async function validateFile(filePath: string, fileInfo: IFileInfo, contentType: string, openStream?: () => Readable): Promise<boolean> {

    if (contentType === "image/vnd.adobe.photoshop") {
        // Not sure how to validate PSD files just yet.
        return true;
    }

    if (contentType.startsWith("image")) {
        return await validateImage(filePath, openStream);
    }
    else if (contentType.startsWith("video")) {
        return await validateVideo(filePath, openStream);
    }

    return true;
}

//
// Validates an image file by checking if it has valid dimensions
//
async function validateImage(filePath: string, openStream?: () => Readable): Promise<boolean> {
    let tempFilePath: string | undefined;
    let actualFilePath = filePath;

    try {
        // If openStream is provided, we need to extract to a temporary file
        if (openStream) {
            tempFilePath = await extractToTempFile(openStream, 'temp_image');
            actualFilePath = tempFilePath;
        }

        const image = new Image(actualFilePath);
        const dimensions = await image.getDimensions();
        
        if (typeof dimensions.width === 'number' && typeof dimensions.height === 'number' && 
            dimensions.width > 0 && dimensions.height > 0) {
            return true;
        } else {
            console.error(`Invalid image ${filePath} - invalid dimensions: ${dimensions.width}x${dimensions.height}`);
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
async function validateVideo(filePath: string, openStream?: () => Readable): Promise<boolean> {
    let tempFilePath: string | undefined;
    let actualFilePath = filePath;

    try {
        // If openStream is provided, we need to extract to a temporary file
        if (openStream) {
            tempFilePath = await extractToTempFile(openStream, 'temp_video');
            actualFilePath = tempFilePath;
        }

        const video = new Video(actualFilePath);
        const dimensions = await video.getDimensions();
        
        if (typeof dimensions.width === 'number' && typeof dimensions.height === 'number' && 
            dimensions.width > 0 && dimensions.height > 0) {
            return true;
        } else {
            console.error(`Invalid video ${filePath} - invalid dimensions: ${dimensions.width}x${dimensions.height}`);
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
async function extractToTempFile(openStream: () => Readable, prefix: string): Promise<string> {
    const tempPath = join(tmpdir(), `${prefix}_${Date.now()}_${Math.random().toString(36).substring(2)}`);
    
    const inputStream = openStream();
    const chunks: Buffer[] = [];
    
    for await (const chunk of inputStream) {
        chunks.push(chunk);
    }
    
    const fileBuffer = Buffer.concat(chunks);
    writeFileSync(tempPath, fileBuffer);
    
    return tempPath;
}

