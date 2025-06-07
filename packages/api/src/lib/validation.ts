import { Readable } from "node:stream";
import { IFileInfo } from "storage";
import { Video } from "tools";
import { writeFileSync, unlinkSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";

const sharp = require('sharp');

//
// Validates that a file is good before allowing it to be added to the merkle tree.
//
export async function validateFile(filePath: string, fileInfo: IFileInfo, contentType: string, openStream: () => Readable): Promise<boolean> {

    if (contentType === "image/vnd.adobe.photoshop") {
        // Not sure how to validate PSD files just yet.
        return true;
    }

    if (contentType.startsWith("image")) {
        const imageStream = sharp();
        openStream().pipe(imageStream);
        const metadata = await imageStream.metadata()
        if (typeof (metadata.width) === 'number' && typeof (metadata.height) === 'number') {
            // console.log(`Image ${filePath} (${fileInfo.contentType}) has dimensions ${metadata.width}x${metadata.height}`);
            return true;
        }
        else {
            console.error(`Invalid image ${filePath} (${contentType})`);
            return false;
        }
    }
    else if (contentType.startsWith("video")) {
        const metadata = await getVideoMetadata(filePath, openStream());
        if (typeof (metadata.width) === 'number' && typeof (metadata.height) === 'number') {
            // console.log(`Video ${filePath} (${fileInfo.contentType}) has dimensions ${metadata.width}x${metadata.height}`);
            return true;
        }
        else {
            console.error(`Invalid video ${filePath} (${contentType})`);
            return false;
        }
    }

    return true;
}

//
// Gets the metadata data for a video using the tools package.
//
export async function getVideoMetadata(filePath: string, inputStream: Readable): Promise<{ width: number, height: number }> {
    // Create a temporary file from the stream since the Video class needs a file path
    const tempPath = join(tmpdir(), `temp_video_${Date.now()}_${Math.random().toString(36).substring(2)}`);
    
    try {
        // Write stream to temporary file
        const chunks: Buffer[] = [];
        for await (const chunk of inputStream) {
            chunks.push(chunk);
        }
        const fileBuffer = Buffer.concat(chunks);
        writeFileSync(tempPath, fileBuffer);
        
        // Use the Video class from tools to get dimensions
        const video = new Video(tempPath);
        const dimensions = await video.getDimensions();
        
        return {
            width: dimensions.width,
            height: dimensions.height,
        };
    } catch (error) {
        throw new Error(`Failed to get video metadata: ${error instanceof Error ? error.message : 'Unknown error'}`);
    } finally {
        // Clean up temporary file
        try {
            unlinkSync(tempPath);
        } catch (err) {
            // Ignore cleanup errors
        }
    }
}
