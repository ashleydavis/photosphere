import { getVideoTransformation, ILocation, uuid } from "utils";
import path from "path";
import fs from "fs-extra";
import os from "os";
import dayjs from "dayjs";
import { resizeImage, transformImage, IResolution } from "node-utils";
import { Readable } from "stream";
import { IAssetDetails, MICRO_MIN_SIZE, MICRO_QUALITY, THUMBNAIL_MIN_SIZE } from "./media-file-database";
import { Video, Image } from "tools";

//
// Writes a stream to a file.
//
export async function writeStreamToFile(stream: Readable, filePath: string): Promise<void> {
    return new Promise((resolve, reject) => {
        const writeStream = fs.createWriteStream(filePath);
        stream.pipe(writeStream);
        writeStream.on('finish', resolve);
        writeStream.on('error', reject);
    });
}

//
// Gets the details of a video.
// 
export async function getVideoDetails(filePath: string, openStream: () => Readable): Promise<IAssetDetails> {

    let videoPath: string;
    let shouldCleanup = false;

    if (filePath.startsWith("zip://")) {
        videoPath = path.join(os.tmpdir(), uuid());
        await writeStreamToFile(openStream(), filePath);        
        shouldCleanup = true;
    }
    else {
        videoPath = filePath;
    }

    try {
        const video = new Video(videoPath);
        const assetInfo = await video.getInfo();
        
        // Extract screenshot at 1 second or middle of video
        const screenshotPath = path.join(os.tmpdir(), `thumb_${uuid()}.jpg`);
        const screenshotTime = Math.min(assetInfo.duration ? assetInfo.duration / 2 : 1, 300); // Max 5 minutes
        await video.extractScreenshot(screenshotPath, screenshotTime);
        
        // Read screenshot as buffer
        const screenshot = await fs.readFile(screenshotPath);
        
        // Clean up screenshot file
        await fs.unlink(screenshotPath);

        let resolution = assetInfo.dimensions;
        let thumbnail = await resizeImage(screenshot, resolution, THUMBNAIL_MIN_SIZE);

        const imageTransformation = await getVideoTransformation(assetInfo.metadata);
        if (imageTransformation) {
            // Flips orientation depending on exif data.
            thumbnail = await transformImage(thumbnail, imageTransformation);
            if (imageTransformation.changeOrientation) {
                resolution = {
                    width: resolution.height,
                    height: resolution.width,
                };
            }
        }

        const micro = await resizeImage(thumbnail, resolution, MICRO_MIN_SIZE, MICRO_QUALITY);

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
            micro, 
            thumbnail, 
            thumbnailContentType: "image/jpeg",
            metadata: assetInfo.metadata,
            coordinates,
            photoDate,
            duration: assetInfo.duration
        };
    } finally {
        if (shouldCleanup) {
            await fs.unlink(videoPath);
        }
    }
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
