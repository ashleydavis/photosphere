import { getVideoTransformation, ILocation, uuid } from "utils";
import path from "path";
import fs from "fs-extra";
import os from "os";
import { IAssetDetails, MICRO_MIN_SIZE, MICRO_QUALITY, THUMBNAIL_MIN_SIZE } from "./asset";
import dayjs from "dayjs";
import { resizeImage, transformImage, IResolution } from "node-utils";
const { execSync } = require('child_process');

const ffmpeg = require('fluent-ffmpeg');
const ffmpegPaths = require('ffmpeg-ffprobe-static');
ffmpeg.setFfmpegPath(ffmpegPaths.ffmpegPath);
ffmpeg.setFfprobePath(ffmpegPaths.ffprobePath);

//
// Gets the details of a video.
// 
export async function getVideoDetails(filePath: string | undefined, fileData: Buffer): Promise<IAssetDetails> {
    const videoPath = filePath || path.join(os.tmpdir(), uuid());
    if (!filePath) {
        await fs.writeFile(videoPath, fileData);
    }

    const assetDetails = await getVideoMetadata(videoPath);
    const screenshot = getVideoScreenshot(videoPath, assetDetails.duration);
    let resolution = await getVideoResolution(videoPath);
    let thumbnail = await resizeImage(screenshot, resolution, THUMBNAIL_MIN_SIZE);

    const imageTransformation = await getVideoTransformation(assetDetails.metadata);
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

    if (assetDetails.photoDate === undefined) {
        //
        // See if we can get photo date from the JSON file.
        //
        const jsonFilePath = filePath + ".json";
        if (await fs.pathExists(jsonFilePath)) {
            const jsonFileData = await fs.readFile(jsonFilePath);
            const photoData = JSON.parse(jsonFileData.toString());
            if (photoData.photoTakenTime?.timestamp) {
                try {
                    assetDetails.photoDate = dayjs.unix(parseInt(photoData.photoTakenTime.timestamp)).toISOString();
                    console.log(`Parsed date ${assetDetails.photoDate} from timestamp ${parseInt(photoData.photoTakenTime.timestamp)} in JSON file ${jsonFilePath}`);
                }
                catch (err) {
                    console.error(`Failed to parse date ${photoData.photoTakenTime.timestamp} from JSON file ${jsonFilePath}`);
                    console.error(err);
                }    
            }
        }
    }

    if (!filePath) {
        await fs.unlink(videoPath);
    }

    return { 
        resolution, 
        micro, 
        thumbnail, 
        ...assetDetails 
    };
}

//
// Gets the resolution of a video.
//
export async function getVideoResolution(videoPath: string): Promise<IResolution> {
    return new Promise((resolve, reject) => {
        ffmpeg.ffprobe(videoPath, (err: any, metadata: any) => {
            if (err) {
                reject(err);
                return;
            }
            const videoStream = metadata.streams.find((stream: any) => stream.codec_type === 'video');
            if (videoStream) {
                const resolution = {
                    width: videoStream.width,
                    height: videoStream.height,
                };
                resolve(resolution);
            } else {
                reject(new Error('No video stream found'));
            }
        });
    });
}


//
// Gets a screenshot from a video.
//
export function getVideoScreenshot(videoPath: string, duration: number | undefined): Buffer {
    const outputFilePath = path.join(os.tmpdir(), `thumbs`, uuid() + '.jpeg');
    const screenshotPosition = Math.min(duration ? duration / 2 : 0, 300); // Maxes out at 5 minutes into the video.
    const cmd = `${ffmpegPaths.ffmpegPath} -y -ss ${screenshotPosition} -i "${videoPath}" -frames:v 1 -q:v 2 "${outputFilePath}"`;
    console.log(cmd);
    execSync(cmd);
  
    if (!fs.existsSync(outputFilePath)) {
        throw new Error(`Failed to create thumbnail from video ${videoPath}`);
    }

    const screenshot = fs.readFileSync(outputFilePath);
    fs.unlinkSync(outputFilePath);
    return screenshot;
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

//
// Gets the metadata data for a video.
//
export function getVideoMetadata(videoPath: string): Promise<{ metadata?: any, coordinates?: ILocation, photoDate?: string, duration?: number }> {
    return new Promise((resolve, reject) => {
        ffmpeg.ffprobe(videoPath, (err: any, metadata: any) => {
            if (err) {
                reject(err);
            }
            else {
                let coordinates: ILocation | undefined = undefined;
                if (metadata.format?.tags?.location) {
                    coordinates = parseVideoLocation(metadata.format.tags.location);
                }
                
                let photoDate: string | undefined = undefined;
                if (metadata.format?.tags?.creation_time) {
                    photoDate = metadata.format.tags.creation_time;
                }

                let duration: number | undefined = undefined;
                if (metadata.format?.duration) {
                    duration = metadata.format.duration;
                }

                resolve({
                    metadata,
                    coordinates,
                    photoDate,
                    duration,
                });
            }
        });
    });
}
