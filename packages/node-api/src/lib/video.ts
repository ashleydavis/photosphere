import { getVideoTransformation, ILocation, log } from "utils";
import * as fs from "fs/promises";
import { pathExists } from "node-utils";
import dayjs from "dayjs";
import { join } from "path";
import { IUuidGenerator } from "utils";
import { IAssetDetails, MICRO_MIN_SIZE, MICRO_QUALITY, THUMBNAIL_MIN_SIZE } from "./media-file-database";
import { getFileInfo, Video } from "tools";
import { resizeImage, transformImage } from "./image";

//
// Gets the details of a video.
// 
export async function getVideoDetails(filePath: string, tempDir: string, contentType: string, uuidGenerator: IUuidGenerator, logicalPath: string): Promise<IAssetDetails> {
    // filePath is always a valid file (already extracted if from zip)
    const videoPath = filePath;

    const metadataStartedAt = Date.now();
    const assetInfo = await getFileInfo(videoPath, contentType);
    const metadataMs = Date.now() - metadataStartedAt;
    if (!assetInfo) {
        throw new Error(`Unsupported file type: ${contentType}`);
    }
    
    // Extract screenshot at 1 second or middle of video
    const video = new Video(videoPath);
    const screenshotPath = join(tempDir, `thumb_${uuidGenerator.generate()}.jpg`);
    const screenshotTime = Math.min(assetInfo.duration ? assetInfo.duration / 2 : 1, 300); // Max 5 minutes
    const screenshotStartedAt = Date.now();
    await video.extractScreenshot(screenshotPath, screenshotTime);
    const screenshotMs = Date.now() - screenshotStartedAt;
    
    let resolution = assetInfo.dimensions;
    const thumbnailStartedAt = Date.now();
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

    const thumbnailMs = Date.now() - thumbnailStartedAt;

    const microStartedAt = Date.now();
    const microPath = await resizeImage(thumbnailPath, tempDir, resolution, MICRO_MIN_SIZE, uuidGenerator, MICRO_QUALITY);
    const microMs = Date.now() - microStartedAt;

    let photoDate = assetInfo.createdAt?.toISOString();
    
    if (photoDate === undefined) {
        //
        // See if we can get photo date from the JSON file.
        //
        const jsonFilePath = filePath + ".json";
        if (await pathExists(jsonFilePath)) {
            const jsonFileData = await fs.readFile(jsonFilePath);
            const photoData = JSON.parse(jsonFileData.toString());
            if (photoData.photoTakenTime?.timestamp) {
                try {
                    photoDate = dayjs.unix(parseInt(photoData.photoTakenTime.timestamp)).toISOString();
                    log.verbose(`Parsed date ${photoDate} from timestamp ${parseInt(photoData.photoTakenTime.timestamp)} in JSON file ${jsonFilePath}`);
                }
                catch (err) {
                    log.exception(`Failed to parse date ${photoData.photoTakenTime.timestamp} from JSON file ${jsonFilePath}`, err as Error);
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
        duration: assetInfo.duration,
        detailTimings: {
            // The frame extraction is counted as metadata rather than as one of the derivative
            // images, because it is not one: it is what a video has to do before there is any image
            // to resize at all, and it is the expensive part of taking a video in.
            metadataMs: metadataMs + screenshotMs,
            microMs,
            thumbnailMs,
            displayMs: 0,
        },
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
