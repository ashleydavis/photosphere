import * as config from "./config";
import { findAssets } from "./scan";
import axios from "axios";
import fs from "fs-extra";
import path from "path";
import os from "os";
import dayjs from "dayjs";
import { IAsset, IDatabaseOp } from "defs";
import _ from "lodash";
import JSZip from "jszip";
import { convertExifCoordinates, getImageTransformation, ILocation, isLocationInRange, retry, reverseGeocode, uuid } from "utils";
import { getImageResolution, IResolution, resizeImage, transformImage } from "node-utils";
const exifParser = require("exif-parser");
const ffmpeg = require('fluent-ffmpeg');
const ffmpegPaths = require('ffmpeg-ffprobe-static');
ffmpeg.setFfmpegPath(ffmpegPaths.ffmpegPath);
ffmpeg.setFfprobePath(ffmpegPaths.ffprobePath);
const { execSync } = require('child_process');
const ColorThief = require("colorthief");

if (!process.env.GOOGLE_API_KEY) {
    throw new Error("GOOGLE_API_KEY environment variable not set.");
}

//
// Size of the micro thumbnail.
//
const MICRO_MIN_SIZE = 40;

//
// Quality of the micro thumbnail.
//
const MICRO_QUALITY = 75;

//
// Size of the thumbnail.
//
const THUMBNAIL_MIN_SIZE = 300;

//
// Quality of the thumbnail.
//
const THUMBNAIL_QUALITY = 90;

//
// Size of the display asset.
//
const DISPLAY_MIN_SIZE = 1000;

//
// Quality of the display asset.
//
const DISPLAY_QUALITY = 95;

//
// Counts the number of uploads.
//
let numUploads = 0;

//
// Counts the number of assets already uploaded.
//
let numAlreadyUploaded = 0; 

//
// Number of uploads where the asset matches. 
//
let numUploadedWithNonMatchingHash = 0;

//
// Number of duplicate assets found against one hash.
//
let numDuplicateAssets = 0;

//
// Number of assets that were correct with Image Magick before upload.
//
let numAssetsCorrected = 0;

//
// Counts the number of failures.
//
let numFailed = 0;

//
// File extensions for files to ignore.
//
const ignoreExts = [
    ".ini",
    ".db",
	".lnk",
	".dat",
	".log",
	".htm",
	".html",
	".pdf",
	".rtf",
	".odt",
	".eml",
	".bin",
	".pln",
	".exe",
	".air",
	".url",
	".contact",
	".download",
	".js",
	".css",
	".php",
	".ico",
	".ithmb",
	".authenticate",
	".log1",
	".log2",
	".blf",
	".regtrans-ms",
	".ZFSendToTarget",
	".xml",
	".DeskLink",
	".MAPIMail",
	".csv",
	".txt",
	".cfg",
	".applesyncinfo",
	".jsx",
	".ashx",
	".searchconnector-ms",
	".3gp",
	".bs",	
    ".json",
    ".bak",
];

//
// Number of files ignored due to extension.
//
let numIgnored = 0;

//
// Processes and uploads a single asset.
//
async function uploadAsset(filePath: string, actualFilePath: string | undefined, contentType: string, fileData: Buffer, labels: string[], fileDate: string): Promise<void> {

    //
    // Computes the hash and checks if we already uploaded this file.
    //
    const hash = await computeHash(fileData);    
    const existingAssetIds = await checkUploaded(config.uploadSetId, hash);
    if (existingAssetIds.length === 1) {
        const existingAssetId = existingAssetIds[0];

        //console.log(`Already uploaded asset ${filePath} with hash ${hash}`);
        numAlreadyUploaded += 1;

        //
        // Checks the exzisting file matches the hash of the local file.
        //
        const existingData = await downloadAssetData(config.uploadSetId, existingAssetId, "asset");
        const existingHash = await computeHash(existingData);
        if (hash !== existingHash) {
            console.error(`BAD: Uploaded asset ${filePath} (${existingAssetId}) with hash ${hash} does not match existing hash ${existingHash}`);
            numUploadedWithNonMatchingHash += 1;
        }
        else {
            // console.log(`OK: Uploaded asset ${filePath} (${existingAssetId}) with hash ${hash} matches existing hash`);
        }

        const assetData = await getAssetMetadata(existingAssetId);
        if (assetData.photoDate === undefined) {
            console.log(`No photo date for asset ${existingAssetId} with hash ${hash}`);

            //
            // See if we can get photo date from the JSON file.
            //
            const jsonFilePath = filePath + ".json";
            if (await fs.pathExists(jsonFilePath)) {
                const jsonFileData = await fs.readFile(jsonFilePath);
                const photoData = JSON.parse(jsonFileData.toString());
                if (photoData.photoTakenTime?.timestamp) {
                    try {
                        const photoDate = dayjs.unix(parseInt(photoData.photoTakenTime.timestamp)).toISOString();
                        console.log(`Parsed date ${assetData.photoDate} from timestamp ${parseInt(photoData.photoTakenTime.timestamp)} in JSON file ${jsonFilePath}`);

                        await updateAsset(existingAssetId, { photoDate });

                        console.log(`Updated asset ${existingAssetId} with photo date ${photoDate}`);
                    }
                    catch (err) {
                        console.error(`Failed to parse date ${photoData.photoTakenTime.timestamp} from JSON file ${jsonFilePath}`);
                        console.error(err);
                    }    
                }
            }            
        }

        return;
    }
    else if (existingAssetIds.length > 1) {
        console.warn(`Multiple assets with hash ${hash} found:`);
        console.warn(existingAssetIds);

        numDuplicateAssets += 1;
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
        try {
            assetDetails = await getImageDetails(filePath, fileData, contentType);
        }
        catch (err) {
            console.log(`Failed to get image details for ${filePath}:`);
            console.log(err);

            console.log(`Will retry after fixing the image.`);

            //
            // If it crashed, fix the image and try again.
            //
            execSync(`cp "${filePath}" "${filePath}.bak"`);
            execSync(`magick "${filePath}" "${filePath}"`);

            numAssetsCorrected += 1;

            assetDetails = await getImageDetails(filePath, fileData, contentType);
        }
    }

    //
    // Uploads the full asset.
    //
    await uploadAssetData(config.uploadSetId, assetId, "asset", contentType, fileData);

    //
    // Uploads the thumbnail.
    //
    await uploadAssetData(config.uploadSetId, assetId, "thumb", "image/jpg", assetDetails.thumbnail);

    if (assetDetails.display) {
        //
        // Uploads the display asset separately for simplicity and no restriction on size.
        //
        await uploadAssetData(config.uploadSetId, assetId, "display", "image/jpg", assetDetails.display);
    }

    const properties: any = {};

    if (assetDetails.metadata) {
        properties.metadata = assetDetails.metadata;
    }

    let coordinates: ILocation | undefined = undefined;
    let location: string | undefined = undefined;
    if (assetDetails.coordinates) {
        coordinates = assetDetails.coordinates;
        const reverseGeocodingResult = await retry(() => reverseGeocode(assetDetails.coordinates!), 3, 1500);
        if (reverseGeocodingResult) {
            location = reverseGeocodingResult.location;
            properties.reverseGeocoding = {
                type: reverseGeocodingResult.type,
                fullResult: reverseGeocodingResult.fullResult,
            };
        }
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
        uploadDate: dayjs().toISOString(),
        properties,
        labels,
        description: "",
        userId: config.userId,
        micro: assetDetails.micro.toString("base64"),
        color: await ColorThief.getColor(assetDetails.thumbnail),
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
		for (const ignoreExt of ignoreExts) {
			if (filePath.toLowerCase().endsWith(ignoreExt.toLowerCase())) {
				numIgnored += 1;
				//console.log(`Ignored ${filePath} due to ext ${ignoreExt}`);
				return undefined;
			}
		}
		
		const ext = path.extname(filePath).toLowerCase();		

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
    console.log(`Uploaded not matching local hash: ${numUploadedWithNonMatchingHash}`);
    console.log(`Duplicate assets: ${numDuplicateAssets}`);
    console.log(`Assets corrected: ${numAssetsCorrected}`);
    console.log(`Failed: ${numFailed}`);
    console.log(`Not handled: ${filesNotHandled.length}`);
	console.log(`Ignored: ${numIgnored}`);

    await fs.ensureDir("./log/failures");
    let failureIndex = 0;
    for (const chunk of _.chunk(failures, 10)) {
        await fs.writeFile(`./log/failures/failures_${failureIndex+1}.json`, JSON.stringify(chunk, null, 2));
        failureIndex += 1;
    }

    await fs.ensureDir("./log/not-handled");
    let notHandledIndex = 0;
    for (const chunk of _.chunk(filesNotHandled, 10)) {
        await fs.writeFile(`./log/not-handled/not-handled-${notHandledIndex+1}.json`, JSON.stringify(chunk, null, 2));
        notHandledIndex += 1;
    }

    await fs.writeFile("./log/summary.json", JSON.stringify({ 
        numFiles: files.length, 
        numProcessed, 
        numUploads, 
        numAlreadyUploaded, 
        numUploadedWithNonMatchingHash,
        numDuplicateAssets, 
        numAssetsCorrected,
        numFailed, 
        numNotHandled: filesNotHandled.length,
    }, null, 2));
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
    // The micro thumbnail of the image/video.
    //
    micro: Buffer;

    //
    // The thumbnail of the image/video.
    //
    thumbnail: Buffer;

    //
    // The display image.
    //
    display?: Buffer;

    //
    // Metadata, if any.
    //
    metadata?: any;

    //
    // GPS coordinates of the asset.
    //
    coordinates?: ILocation;

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
    const micro = await resizeImage(thumbnail, resolution, MICRO_MIN_SIZE, MICRO_QUALITY);
    const assetDetails = await getVideoMetadata(videoPath);

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
function getVideoMetadata(videoPath: string): Promise<{ metadata?: any, coordinates?: ILocation, photoDate?: string }> {
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

    const assetDetails = await getImageMetadata(filePath, fileData, contentType);
    const imageTransformation = await getImageTransformation(assetDetails.metadata);
    if (imageTransformation) {
        fileData = await transformImage(fileData, imageTransformation);
    }

    const resolution = await getImageResolution(filePath, fileData);
    const micro = await resizeImage(fileData, resolution, MICRO_MIN_SIZE, MICRO_QUALITY);
    const thumbnail = await resizeImage(fileData, resolution, THUMBNAIL_MIN_SIZE, THUMBNAIL_QUALITY);
    const display = await resizeImage(fileData, resolution, DISPLAY_MIN_SIZE, DISPLAY_QUALITY);

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

    return { 
        resolution, 
        micro,
        thumbnail, 
        display,
        ...assetDetails 
    };
}

//
// Gets the metadata from the image.
//
async function getImageMetadata(filePath: string, fileData: Buffer, contentType: string): Promise<{ metadata?: any, coordinates?: ILocation, photoDate?: string }> {
    if (contentType === "image/jpeg" || contentType === "image/jpg") {
        try {
            let coordinates: ILocation | undefined = undefined;
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
export async function checkUploaded(setId: string, hash: string): Promise<string[]> {
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

    return response.data.assetIds;
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
// Downloads the data for an asset.
//
async function downloadAssetData(setId: string, assetId: string, assetType: string): Promise<Buffer> {
    const response = await axios.get(
        `${config.backend}/asset?set=${setId}&id=${assetId}&type=${assetType}`, 
        {
			responseType: "arraybuffer",
            headers: {
                Authorization: `Bearer ${config.token}`,
                Accept: "image/*,video/*",
            },
        }
    );
    return Buffer.from(response.data, 'binary');
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

//
// Gets the metadata for an asset.
//
async function getAssetMetadata(assetId: string): Promise<IAsset>  {
    const url = `${config.backend}/get-one?col=metadata&id=${assetId}`;
    const response = await axios.get(
        url, 
        {
            headers: {
                Authorization: `Bearer ${config.token}`,
                Accept: "application/json",
            },
        }
    );
    return response.data;
}

//
// Applies a partial update to an asset.
//
async function updateAsset(assetId: string, assetPartial: Partial<IAsset>): Promise<void> {
    //
    // Add the asset to the database.
    //
    const ops: IDatabaseOp[] = [
        {
            collectionName: "metadata",
            recordId: assetId,
            op: {
                type: "set",
                fields: assetPartial,
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
