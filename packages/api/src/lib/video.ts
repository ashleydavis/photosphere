import { getVideoTransformation, ILocation } from "utils";
import path from "path";
import fs from "fs-extra";
import dayjs from "dayjs";
import { writeStreamToFile } from "node-utils";
import { tmpdir } from "os";
import { join } from "path";
import { IUuidGenerator } from "utils";
import { Readable } from "stream";
import { IAssetDetails, MICRO_MIN_SIZE, MICRO_QUALITY, THUMBNAIL_MIN_SIZE } from "./media-file-database";
import { getFileInfo, Video } from "tools";
import { resizeImage, transformImage } from "./image";
import mime from 'mime';

//
// Gets the details of a video.
// 
export async function getVideoDetails(filePath: string, tempDir: string, contentType: string, uuidGenerator: IUuidGenerator, openStream?: () => NodeJS.ReadableStream): Promise<IAssetDetails> {

    let videoPath: string;

    if (openStream) {
        // Choose extension based on content type.            
        const ext = mime.getExtension(contentType);
        if (!ext) {
            throw new Error(`Unsupported content type: ${contentType}`);
        }

        // If openStream is provided, we need to extract to a temporary file.
        videoPath = join(tmpdir(), `temp_video_${uuidGenerator.generate()}.${ext}`);
        await writeStreamToFile(openStream(), videoPath);        
    }
    else {
        // Use the file directly from its location on disk.
        videoPath = filePath;
    }

    const assetInfo = await getFileInfo(videoPath, contentType);
    if (!assetInfo) {
        throw new Error(`Unsupported file type: ${contentType}`);
    }
    
    // Extract screenshot at 1 second or middle of video
    const video = new Video(videoPath);
    const screenshotPath = join(tmpdir(), `thumb_${uuidGenerator.generate()}.jpg`);
    const screenshotTime = Math.min(assetInfo.duration ? assetInfo.duration / 2 : 1, 300); // Max 5 minutes
    await video.extractScreenshot(screenshotPath, screenshotTime);
    
    let resolution = assetInfo.dimensions;
    let thumbnailPath = await resizeImage(screenshotPath, tempDir, resolution, THUMBNAIL_MIN_SIZE, uuidGenerator);

    const imageTransformation = await getVideoTransformation(assetInfo.metadata);
    if (imageTransformation) {
        // Flips orientation depending on exif data.
        thumbnailPath = await transformImage(thumbnailPath, tempDir, imageTransformation, uuidGenerator);
        if (imageTransformation.changeOrientation) {
            resolution = {
                width: resolution.height,
                height: resolution.width,
            };
        }
    }

    const microPath = await resizeImage(thumbnailPath, tempDir, resolution, MICRO_MIN_SIZE, uuidGenerator, MICRO_QUALITY);

    let photoDate = assetInfo.createdAt?.toISOString();
    
    if (photoDate === undefined) {
        //
        // See if we can get photo date from the JSON file.
        //
        const jsonFilePath = filePath + ".json";
        if (await fs.pathExists(jsonFilePath)) {
            const jsonFileData = await fs.readFile(jsonFilePath);
            const photoData = JSON.parse(jsonFileData.toString());
            if (photoData.photoTakenTime?.timestamp) {
                try {
                    photoDate = dayjs.unix(parseInt(photoData.photoTakenTime.timestamp)).toISOString();
                    console.log(`Parsed date ${photoDate} from timestamp ${parseInt(photoData.photoTakenTime.timestamp)} in JSON file ${jsonFilePath}`);
                }
                catch (err) {
                    console.error(`Failed to parse date ${photoData.photoTakenTime.timestamp} from JSON file ${jsonFilePath}`);
                    console.error(err);
                }    
            }
        }
    }

    // Extract GPS coordinates from video metadata
    let coordinates: ILocation | undefined = undefined;
    if (assetInfo.metadata?.location) {
        coordinates = parseVideoLocation(assetInfo.metadata.location);
    }

    return { 
        resolution, 
        microPath, 
        thumbnailPath, 
        thumbnailContentType: "image/jpeg",
        metadata: assetInfo.metadata,
        coordinates,
        photoDate,
        duration: assetInfo.duration
    };
}

const videoLocationRegex = /([+-]\d+\.\d+)([+-]\d+\.\d+)/;

//
// Parses the location of the video.
//
function parseVideoLocation(location: string): ILocation | undefined {
    const match = location.match(videoLocationRegex);
    if (match) {
        return {
            lat: parseFloat(match[1]),
            lng: parseFloat(match[2])
        };
    }

    return undefined;
}
