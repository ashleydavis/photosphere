import * as config from "./config";
import { findAssets } from "./scan";
import axios from "axios";
import fs from "fs-extra";
import path from "path";
import sharp from "sharp";
import os from "os";
import dayjs from "dayjs";
import { IAsset, IDatabaseOp } from "defs";
import { ILocation as ICoordinates, IResolution, convertExifCoordinates, isLocationInRange, retry, reverseGeocode, uuid } from "user-interface";
import _ from "lodash";
import JSZip from "jszip";
const exifParser = require("exif-parser");
const ffmpeg = require('fluent-ffmpeg');
const ffmpegPaths = require('ffmpeg-ffprobe-static');
ffmpeg.setFfmpegPath(ffmpegPaths.ffmpegPath);
ffmpeg.setFfprobePath(ffmpegPaths.ffprobePath);

if (!process.env.GOOGLE_API_KEY) {
    throw new Error("GOOGLE_API_KEY environment variable not set.");
}

//
// Size of the thumbnail.
//
const THUMBNAIL_MIN_SIZE = 300;

//
// Size of the display asset.
//
const DISPLAY_MIN_SIZE = 1000;

//
// Counts the number of uploads.
//
let numUploads = 0;

//
// Counts the number of assets already uploaded.
//
let numAlreadyUploaded = 0; 

//
// Counts the number of failures.
//
let numFailed = 0;

//
// File extensions for files to ignore.
//
const ignoreExts = [
    "ini",
    "db",
];

//
// Processes and uploads a single asset.
//
async function uploadAsset(filePath: string, actualFilePath: string | undefined, contentType: string, fileData: Buffer, labels: string[], fileDate: string): Promise<void> {

    //
    // Computes the hash and checks if we already uploaded this file.
    //
    const hash = await computeHash(fileData);    
    if (await checkUploaded(config.uploadSetId, hash)) {
        //console.log(`Already uploaded asset ${filePath} with hash ${hash}`);
        numAlreadyUploaded += 1;
        return;
    }    
    
    const assetId = uuid();

    // console.log(`Uploading asset ${filePath} with id ${assetId} and hash ${hash}`);

    let assetDetails: IAssetDetails;

    //
    // Get asset resolution.
    //
    if (contentType.startsWith("video")) {
        assetDetails = await getVideoDetails(actualFilePath, fileData);
    }
    else {
        assetDetails = await getImageDetails(filePath, fileData, contentType);
    }

    //
    // Uploads the full asset.
    //
    await uploadAssetData(config.uploadSetId, assetId, "asset", contentType, fileData);

    //
    // Uploads the thumbnail.
    //
    await uploadAssetData(config.uploadSetId, assetId, "thumb", "image/jpg", assetDetails.thumbnail);

    if (contentType.startsWith("image")) {
        //
        // Uploads the display asset separately for simplicity and no restriction on size.
        //
        const displayData = await resizeImage(fileData, assetDetails.resolution, DISPLAY_MIN_SIZE);
        await uploadAssetData(config.uploadSetId, assetId, "display", "image/jpg", displayData);
    }

    const properties: any = {};

    if (assetDetails.metadata) {
        properties.metadata = assetDetails.metadata;
    }

    let coordinates: ICoordinates | undefined = undefined;
    let location: string | undefined = undefined;
    if (assetDetails.coordinates) {
        coordinates = assetDetails.coordinates;
        location = await retry(() => reverseGeocode(assetDetails.coordinates!), 3, 1500);
    }

    //
    // Read the date of the file.
    //
    const fileDir = path.dirname(filePath);
    labels = labels.concat(fileDir.replace(/\\/g, "/")
        .split("/")
        .filter(label => label)
        .filter(label => {
            const labelLwr = label.toLowerCase();
            if (labelLwr === "z:" || labelLwr === "photos" || labelLwr === "photo library") {
                return false;
            }

            return true;
        }));

    //
    // Add asset to the gallery.
    //
    await addAsset({
        _id: assetId,
        setId: config.uploadSetId,
        width: assetDetails.resolution.width,
        height: assetDetails.resolution.height,
        origFileName: path.basename(filePath),
        origPath: fileDir,
        contentType,
        hash,
        coordinates,
        location,
        fileDate,
        photoDate: assetDetails.photoDate,
        sortDate: assetDetails.photoDate || fileDate,
        uploadDate: dayjs().toISOString(),
        properties,
        labels,
        description: "",
        userId: config.userId,
    });   

    numUploads += 1;

    console.log(`Uploaded asset ${filePath} (${contentType}) with id ${assetId} and hash ${hash}`);
}

//
// Maps supported file extensions to content type.
//
const extMap: { [index: string]: string } = {
    '.jpg': "image/jpeg", 
    '.jpeg': "image/jpeg", 
    '.png': "image/png", 
    '.gif': "image/gif", 
    // '.bmp': "image/bmp", Not supported by sharp.
    '.tiff': "image/tiff", 
    '.webp': "image/webp",
    '.mpg': "video/mpeg",
    '.mpeg': "video/mpeg",
    '.mp4': "video/mp4",
    '.mov': "video/quicktime",
    '.avi': "video/x-msvideo",
    ".mkv": "video/x-matroska",
    ".wmv": "video/x-ms-wmv",
    ".webm": "video/webm",
    ".ogg": "video/ogg",
    ".ogv": "video/ogg",
    ".zip": "application/zip",
};

//
// Gets the content type for a file based on its extension.
//
export function getContentType(filePath: string): string | undefined {
    const ext = path.extname(filePath).toLowerCase();
    return extMap[ext];
}

async function main(): Promise<void> {

    const files: string[] = [];
    const failures: { filePath: string, error: any }[] = [];
    const filesNotHandled: string[] = [];

    //
    // Validates an asset and returns the content type.
    // Returns undefined if the asset is to be ignored.
    //
    function validateAsset(filePath: string): string | undefined {
        const ext = path.extname(filePath).toLowerCase();
        if (ignoreExts.includes(ext)) {
            // Certain extensions can be ignored and we just don't need to know about them.
            return undefined;
        }

        // Check if the file is a supported asset based on its extension.
        const contentType = extMap[ext];
        if (!contentType) {
            filesNotHandled.push(filePath);
            return undefined;
        }

        return contentType;
    }

    //
    // Unpacks a zip file.
    //
    async function handleZipFile(filePath: string): Promise<void> {
        // console.log(`Processing zip file: ${filePath}`);

        const stats = await fs.stat(filePath);
        const fileDate = dayjs(stats.birthtime).toISOString();

        const zip = new JSZip();
        const unpacked = await zip.loadAsync(await fs.readFile(filePath));
        for (const [fileName, zipObject] of Object.entries(unpacked.files)) {
            if (!zipObject.dir) {
                const fullPath = `${filePath}/${fileName}`;
                // console.log(fullPath);

                const contentType = validateAsset(fullPath);
                if (!contentType) {
                    continue;
                }

                try {
                    const fileData = await zipObject.async("nodebuffer");
                
                    await retry(() => uploadAsset(fullPath, undefined, contentType, fileData, ["From zip file"], fileDate), 3, 100);
                }
                catch (error: any) {
                    console.error(`Failed to upload asset: ${fullPath}`);
                    console.error(error.stack || error.message || error);
                    numFailed += 1; 
                    failures.push({ filePath, error });                
                }
            }
        }
    }
	
    //
    // Handles a generic asset.
    //
	async function handleAsset(filePath: string): Promise<void> {
        const contentType = validateAsset(filePath);
        if (!contentType) {
            return;
        }

		try {
            if (contentType === "application/zip") {
                await handleZipFile(filePath);
                return;
            }

            //
            // Load file data.
            // 
            const fileData = await fs.readFile(filePath);

            const stats = await fs.stat(filePath);
            const fileDate = dayjs(stats.birthtime).toISOString();

            await retry(() => uploadAsset(filePath, filePath, contentType, fileData, [], fileDate), 3, 100);
		}
		catch (error: any) {
			console.error(`Failed to upload asset: ${filePath}`);
			console.error(error.stack || error.message || error);
			numFailed += 1; 
			failures.push({ filePath, error });                
		}
	}	

    console.log(`Scanning for assets...`);

    for (const scanPath of config.paths) {        
        console.log(`Scanning path: ${scanPath}`);
        await findAssets(scanPath, config.ignoreDirs, async filePath => { 
            files.push(filePath) 
        });
    }    

    await fs.ensureDir("./log");
    await fs.writeFile("./log/files.json", JSON.stringify(files, null, 2));

    console.log(`Found ${files.length} assets.`);

    let numProcessed = 0;

    for (const chunk of _.chunk(files, config.batchSize)) {
        await Promise.all(chunk.map(handleAsset));

        numProcessed += chunk.length;
        if ((numProcessed % 100) === 0) {
            console.log(`Processed ${numProcessed} of ${files.length} assets.`);
        }
    }

    // console.log(`-- Failures --`);
    // for (const failure of failures) {
    //     console.error(`Failed to upload asset: ${failure.filePath}`);
    //     console.error(failure.error);
    // }

    // console.log(`-- Files not handled --`);
    // for (const filePath of filesNotHandled) {
    //     console.log(filePath);
    // }

    console.log(`-- Summary --`);
    console.log(`Total files found: ${files.length}`);
    console.log(`Processed: ${numProcessed}`);
    console.log(`Uploaded: ${numUploads}`);
    console.log(`Already uploaded: ${numAlreadyUploaded}`);
    console.log(`Failed: ${numFailed}`);
    console.log(`Not handled: ${filesNotHandled.length}`);

    await fs.writeFile("./log/failures.json", JSON.stringify(failures, null, 2));
    await fs.writeFile("./log/files-not-handled.json", JSON.stringify(filesNotHandled, null, 2));
    await fs.writeFile("./log/summary.json", JSON.stringify({ numFiles: files.length, numProcessed, numUploads, numAlreadyUploaded, numFailed, numNotHandled: filesNotHandled.length }, null, 2));
}

main()
    .catch(err => {
        console.error(`Failed:`);
        console.error(err && err.stack || err);
    });

export interface IAssetDetails {
    //
    // The resolution of the image/video.
    //
    resolution: IResolution;

    //
    // The thumbnail of the image/video.
    //
    thumbnail: Buffer;

    //
    // Metadata, if any.
    //
    metadata?: any;

    //
    // GPS coordinates of the asset.
    //
    coordinates?: ICoordinates;

    //
    // Date of the asset.
    //
    photoDate?: string;
}

//
// Gets the details of a video.
// 
async function getVideoDetails(filePath: string | undefined, fileData: Buffer): Promise<IAssetDetails> {
    const videoPath = filePath || path.join(os.tmpdir(), uuid());
    if (!filePath) {
        await fs.writeFile(videoPath, fileData);
    }

    const resolution = await getVideoResolution(videoPath);
    const thumbnail = await getVideoThumbnail(videoPath, resolution, THUMBNAIL_MIN_SIZE);
    const videoDetails = { resolution, thumbnail, ...await getVideoMetadata(videoPath) };

    if (!filePath) {
        await fs.unlink(videoPath);
    }

    return videoDetails;
}

//
// Gets the resolution of a video.
//
async function getVideoResolution(videoPath: string): Promise<IResolution> {
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
// Gets a thumbnail for a video.
//
function getVideoThumbnail(videoPath: string, resolution: IResolution, minSize: number): Promise<Buffer> {
    return new Promise<Buffer>((resolve, reject) => {
        let width: number;
        let height: number;
    
        if (resolution.width > resolution.height) {
            height = minSize;
            width = Math.trunc((resolution.width / resolution.height) * minSize);
        } 
        else {
            height = Math.trunc((resolution.height / resolution.width) * minSize);
            width = minSize;
        }

        const thumbnailFilePath = path.join(os.tmpdir(), `thumbs`, uuid() + '.jpg');
        ffmpeg(videoPath)
            .on('end', () => {
                resolve(fs.readFileSync(thumbnailFilePath));
                fs.unlinkSync(thumbnailFilePath);
            })
            .on('error', (err: any) => {
                reject(err);
            })
            .screenshots({
                count: 1,
                folder: path.dirname(thumbnailFilePath),
                filename: path.basename(thumbnailFilePath),
                size: `${width}x${height}`, 
            });
    });
}

const videoLocationRegex = /([+-]\d+\.\d+)([+-]\d+\.\d+)/;

//
// Parses the location of the video.
//
function parseVideoLocation(location: string): ICoordinates | undefined {
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
function getVideoMetadata(videoPath: string): Promise<{ metadata?: any, coordinates?: ICoordinates, photoDate?: string }> {
    return new Promise((resolve, reject) => {
        ffmpeg.ffprobe(videoPath, (err: any, metadata: any) => {
            if (err) {
                reject(err);
            }
            else {
                let coordinates: ICoordinates | undefined = undefined;
                if (metadata.format?.tags?.location) {
                    coordinates = parseVideoLocation(metadata.format.tags.location);
                }
                
                let photoDate: string | undefined = undefined;
                if (metadata.format?.tags?.creation_time) {
                    photoDate = metadata.format.tags.creation_time;
                }

                resolve({
                    metadata,
                    coordinates,
                    photoDate,
                });
            }
        });
    });
}

//
// Gets the details of an image.
//
async function getImageDetails(filePath: string, fileData: Buffer, contentType: string): Promise<IAssetDetails> {
    const resolution = await getImageResolution(filePath, fileData);
    const thumbnail = await resizeImage(fileData, resolution, THUMBNAIL_MIN_SIZE);
    return { resolution, thumbnail, ...await getImageMetadata(filePath, fileData, contentType) };
}

//
// Gets the resolution of an image.
//
async function getImageResolution(filePath: string, fileData: Buffer): Promise<IResolution> {
    //
    // Get image resolution.
    //
    const fullImage = sharp(fileData);
    const { width, height } = await fullImage.metadata();
    if (width === undefined || height === undefined) {
        throw new Error(`Failed to get image resolution for ${filePath}`);
    }

    return { width, height };
}

//
// Gets the metadata from the image.
//
async function getImageMetadata(filePath: string, fileData: Buffer, contentType: string): Promise<{ metadata?: any, coordinates?: ICoordinates, photoDate?: string }> {
    if (contentType === "image/jpeg" || contentType === "image/jpg") {
        try {
            let coordinates: ICoordinates | undefined = undefined;
            let photoDate: string | undefined = undefined;

            const parser = exifParser.create(fileData.buffer);
            parser.enableSimpleValues(false);
            const exif = parser.parse();
            if (exif && exif.tags && exif.tags.GPSLatitude && exif.tags.GPSLongitude) {
                coordinates = convertExifCoordinates(exif.tags);
                if (!isLocationInRange(coordinates)) {
                    console.error(`Ignoring out of range GPS coordinates: ${JSON.stringify(coordinates)}, for asset ${filePath}.`);
                    coordinates = undefined;
                }
            }

            const dateFields = ["DateTime", "DateTimeOriginal", "DateTimeDigitized"];
            for (const dateField of dateFields) {
                const dateStr = exif.tags[dateField];
                if (dateStr) {
                    try {
                        photoDate = dayjs(dateStr, "YYYY:MM:DD HH:mm:ss").toISOString();
                    }
                    catch (err) {
                        console.error(`Failed to parse date from ${dateStr}`);
                        console.error(err);
                    }
                }
            }

            return {
                metadata: exif.tags,
                coordinates,
                photoDate
            };
        }
        catch (err) {
            console.error(`Failed to get exif data from ${filePath}`);
            console.error(err);

            return {};
        }
    }
    else {
        return {};
    }
}

//
// Computes a hash for a file or blob of data.
// 
// https://developer.mozilla.org/en-US/docs/Web/API/SubtleCrypto/digest
// https://github.com/jsdom/jsdom/issues/1612#issuecomment-663210638
// https://www.npmjs.com/package/@peculiar/webcrypto
// https://github.com/PeculiarVentures/webcrypto-docs/blob/master/README.md
//
export async function computeHash(data: Buffer) {
    const hashBuffer = await crypto.subtle.digest('SHA-256', data);
    const hashArray = Array.from(new Uint8Array(hashBuffer));
    const hashHex = hashArray.map((b) => b.toString(16).padStart(2, '0')).join('');
    return hashHex;
}

//
// Checks if the asset is already uploaded.
//
export async function checkUploaded(setId: string, hash: string): Promise<boolean> {
    const url = `${config.backend}/check-hash?hash=${hash}&set=${setId}`;
    const response = await axios.get(
        url, 
        {
            headers: {
                Authorization: `Bearer ${config.token}`,
                Accept: "application/json",
            },
        }
    );

    return response.data.assetIds.length > 0;
}

//
// Resize an image.
//
export async function resizeImage(inputData: Buffer, resolution: { width: number, height: number }, minSize: number): Promise<Buffer> {

    let width: number;
    let height: number;

    if (resolution.width > resolution.height) {
        height = minSize;
        width = Math.trunc((resolution.width / resolution.height) * minSize);
    } 
    else {
        height = Math.trunc((resolution.height / resolution.width) * minSize);
        width = minSize;
    }

    return await sharp(inputData)
        .resize(width, height, {
            fit: sharp.fit.fill,
        })
        .jpeg()
        .toBuffer();
}

//
// Uploads the data for an asset.
//
async function uploadAssetData(setId: string, assetId: string, assetType: string, contentType: string, data: Buffer): Promise<void> {
    await axios.post(
        `${config.backend}/asset`, 
        data, 
        {
			maxContentLength: Infinity,
			maxBodyLength: Infinity,
            headers: {
                "content-type": contentType,
                set: setId,
                id: assetId,
                "asset-type": assetType,
                Authorization: `Bearer ${config.token}`,
                Accept: "application/json",
            },
        }
    );
}

//
// Adds an asset to the start of the gallery.
//
async function addAsset(asset: IAsset): Promise<void> {
    //
    // Add the asset to the database.
    //
    const ops: IDatabaseOp[] = [
        {
            collectionName: "metadata",
            recordId: asset._id,
            op: {
                type: "set",
                fields: asset,
            },
        }
    ];

    await axios.post(
        `${config.backend}/operations`, 
        {
            ops,
            clientId: config.clientId,
        },
        {
            headers: {
                Authorization: `Bearer ${config.token}`,
                Accept: "application/json",
            },
        }
    );    

}

