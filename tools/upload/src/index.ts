import * as config from "./config";
import { findAssets } from "./scan";
import axios from "axios";
import fs from "fs";
import path from "path";
import sharp from "sharp";
import os from "os";
import dayjs from "dayjs";
import { IAsset, IDatabaseOp } from "defs";
import { IResolution, convertExifCoordinates, isLocationInRange, retry, reverseGeocode, uuid } from "user-interface";
const exifParser = require("exif-parser");
const ffmpeg = require('fluent-ffmpeg');
const ffmpegPaths = require('ffmpeg-ffprobe-static');
ffmpeg.setFfmpegPath(ffmpegPaths.ffmpegPath);
ffmpeg.setFfprobePath(ffmpegPaths.ffprobePath);

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
async function uploadAsset(filePath: string, contentType: string): Promise<void> {

    //
    // Load file data.
    // 
    const fileData = await fs.promises.readFile(filePath);

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

    let resolution: IResolution | undefined = undefined;

    //
    // Get asset resolution.
    //
    if (contentType.startsWith("video")) {
        resolution = await getVideoResolution(filePath);
    }
    else {
        resolution = await getImageResolution(filePath, fileData);
    }

    //
    // Uploads the full asset.
    //
    await uploadAssetData(config.uploadSetId, assetId, "asset", contentType, fileData);

    if (contentType.startsWith("video")) {
        //
        // Uploads the thumbnail.
        //
        const thumbnailData = await getVideoThumbnail(filePath, resolution, THUMBNAIL_MIN_SIZE);
        await uploadAssetData(config.uploadSetId, assetId, "thumb", "image/jpg", thumbnailData);
    }
    else {
        //
        // Uploads the thumbnail.
        //
        const thumbnailData = await resizeImage(fileData, resolution, THUMBNAIL_MIN_SIZE);
        await uploadAssetData(config.uploadSetId, assetId, "thumb", "image/jpg", thumbnailData);

        //
        // Uploads the display asset separately for simplicity and no restriction on size.
        //
        const displayData = await resizeImage(fileData, resolution, DISPLAY_MIN_SIZE);
        await uploadAssetData(config.uploadSetId, assetId, "display", "image/jpg", displayData);
    }

    const properties: any = {};
    let location: string | undefined = undefined;
    let photoDate: string | undefined = undefined;

    if (contentType === "image/jpeg" || contentType === "image/jpg") {
		try {
			const parser = exifParser.create(fileData.buffer);
			parser.enableSimpleValues(false);
			const exif = parser.parse();
			properties.exif = exif.tags;
			if (exif && exif.tags && exif.tags.GPSLatitude && exif.tags.GPSLongitude) {
				const coordinates = convertExifCoordinates(exif.tags);
				if (isLocationInRange(coordinates)) {
					location = await retry(() => reverseGeocode(coordinates), 3, 1500);
				}
				else {
					console.error(`Ignoring out of range GPS coordinates: ${JSON.stringify(location)}, for asset ${filePath}.`);
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
		}
		catch (err) {
			console.error(`Failed to get exif data from ${filePath}`);
			console.error(err);
		}
    }

    //
    // Read the date of the file.
    //
    const stats = await fs.promises.stat(filePath);
    const fileDate = dayjs(stats.birthtime).toISOString();
    const fileDir = path.dirname(filePath);
    const labels = fileDir.replace(/\\/g, "/")
        .split("/")
        .filter(label => label)
        .filter(label => {
            const labelLwr = label.toLowerCase();
            if (labelLwr === "z:" || labelLwr === "photos" || labelLwr === "photo library") {
                return false;
            }

            return true;
        });

    //
    // Add asset to the gallery.
    //
    await addAsset({
        _id: assetId,
        setId: config.uploadSetId,
        width: resolution.width,
        height: resolution.height,
        origFileName: path.basename(filePath),
        origPath: fileDir,
        contentType,
        hash,
        location,
        fileDate,
        photoDate,
        sortDate: photoDate || fileDate,
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
};

//
// Gets the content type for a file based on its extension.
//
export function getContentType(filePath: string): string | undefined {
    const ext = path.extname(filePath).toLowerCase();
    return extMap[ext];
}

async function main(): Promise<void> {

    const failures: { filePath: string, error: any }[] = [];
    const filesNotHandled: string[] = [];
	
	async function handleAsset(filePath: string): Promise<void> {
		const ext = path.extname(filePath).toLowerCase();
		if (ignoreExts.includes(ext)) {
			// Certain extensions can be ignored and we just don't need to know about them.
			return;
		}

		// Check if the file is a supported asset based on its extension.
		const contentType = extMap[ext];
		if (!contentType) {
			filesNotHandled.push(filePath);
			return;
		}

		try {
		   await retry(() => uploadAsset(filePath, contentType), 3, 100);
		}
		catch (error: any) {
			console.error(`Failed to upload asset: ${filePath}`);
			console.error(error.stack || error.message || error);
			numFailed += 1; 
			failures.push({ filePath, error });                
		}
	}	

    for (const scanPath of config.paths) {        
        console.log(`Scanning path: ${scanPath}`);
        await findAssets(scanPath, config.ignoreDirs, handleAsset);
    }    

    console.log(`-- Failures --`);
    for (const failure of failures) {
        console.error(`Failed to upload asset: ${failure.filePath}`);
        console.error(failure.error);
    }

    console.log(`-- Files not handled --`);
    for (const filePath of filesNotHandled) {
        console.log(filePath);
    }

    console.log(`-- Summary --`);
    console.log(`Uploaded: ${numUploads}`);
    console.log(`Already uploaded: ${numAlreadyUploaded}`);
    console.log(`Failed: ${numFailed}`);
}

main()
    .catch(err => {
        console.error(`Failed:`);
        console.error(err && err.stack || err);
    });

//
// Gets the resolution of a video.
//
function getVideoResolution(videoPath: string): Promise<IResolution> {
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

